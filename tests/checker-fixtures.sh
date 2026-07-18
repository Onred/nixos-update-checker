#!/usr/bin/env bash

set -euo pipefail

checker=${1:-src/checker.sh}
project=$(readlink -f "$(dirname "$0")/..")
fixtures="$project/tests/fixtures"
work=$(mktemp -d -t nixos-update-checker-test.XXXXXX)
lock_holder=""

cleanup_test() {
  if [[ -n "$lock_holder" ]]; then
    kill "$lock_holder" 2>/dev/null || true
    wait "$lock_holder" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup_test EXIT

mkdir -p "$work/repository" "$work/profiles" "$work/state"
install -m 0644 "$fixtures/flake.nix" "$work/repository/flake.nix"
install -m 0644 "$fixtures/flake.lock" "$work/repository/flake.lock"
mkdir -p "$work/systems/running" "$work/systems/boot" "$work/systems/candidate"
ln -s "$work/systems/running" "$work/profiles/system-38-link"
ln -s "$work/systems/boot" "$work/profiles/system-39-link"
ln -s "$work/systems/running" "$work/running-link"
ln -s "$work/systems/running" "$work/boot-link"

run_checker() {
  env \
    PATH="$fixtures/bin:$PATH" \
    NIXOS_UPDATE_CHECKER_FIXTURES="$fixtures" \
    NIXOS_UPDATE_CHECKER_DISCOVERY="$project/nix/discovery.nix" \
    NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM="$work/running-link" \
    NIXOS_UPDATE_CHECKER_BOOT_SYSTEM="$work/boot-link" \
    NIXOS_UPDATE_CHECKER_PROFILE_DIRECTORY="$work/profiles" \
    NIXOS_UPDATE_CHECKER_STATE="$work/state/system-lock.json" \
    NIXOS_UPDATE_CHECKER_HOSTNAME=fixture \
    NIXOS_UPDATE_CHECKER_LOCK="${NIXOS_UPDATE_CHECKER_LOCK:-}" \
    NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT="${NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT:-30}" \
    NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION=old-nixpkgs-revision \
    FAKE_RUNNING_SYSTEM="$(readlink -f "$work/running-link")" \
    FAKE_BOOT_SYSTEM="$(readlink -f "$work/boot-link")" \
    FAKE_CANDIDATE_SYSTEM="$work/systems/candidate" \
    FAKE_DECLARED_DERIVER="${FAKE_DECLARED_DERIVER:-/nix/store/different.drv}" \
    "$checker" "$@"
}

report="$work/report.json"
candidate_lock="$work/candidate.lock"
run_checker --report "$report" --candidate-lock "$candidate_lock" "$work/repository"

# The scheduled path is a no-build preview with a stable terminal JSON contract.
jq -e '
  .schemaVersion == 3 and .status == "success" and
  .analysis.mode == "preview" and
  .analysis.candidateClosureComplete == false and
  .inputBaseline.complete == false and
  .system.running.generation == 38 and
  .system.boot.generation == 38 and
  .buildPlan.localBuildCount == 1 and
  .build.sizeKnown == false and
  (.inputs | map(select(
    .name == "nixpkgs" and
    .before.revision == "old-nixpkgs-revision" and
    .after.revision == "new-nixpkgs-revision"
  )) | length) == 1 and
  (.packages.changes[] | select(.name == "firefox") | .deltaBytes) == 0
' "$report" >/dev/null
[[ -s "$candidate_lock" ]]

# Building is explicit and replaces the preview with an exact closure report.
run_checker --build --report "$report" --candidate-lock "$candidate_lock" "$work/repository"
jq -e '
  .schemaVersion == 3 and .status == "success" and
  .analysis.mode == "verified" and
  .analysis.candidateClosureComplete == true and
  .build.sizeKnown == true and
  (.packages.changes[] | select(.name == "added") | .deltaBytes) == 50 and
  (.packages.changes[] | select(.name == "removed") | .deltaBytes) == -30 and
  .packages.rebuilds.count == 1 and
  .packages.rebuilds.deltaBytes == 1
' "$report" >/dev/null

# A newer default generation is selected as the baseline and reports ready-to-boot.
ln -sfn "$work/systems/boot" "$work/boot-link"
FAKE_DECLARED_DERIVER=/nix/store/boot.drv \
  run_checker --report "$work/boot-report.json" \
    --candidate-lock "$work/boot-candidate.lock" "$work/repository"
jq -e '
  .inputBaseline.source == "workingConfiguration" and
  .inputBaseline.complete == true and
  .system.running.generation == 38 and
  .system.boot.generation == 39 and
  .system.baseline == "boot" and .system.readyForBoot == true
' "$work/boot-report.json" >/dev/null

# Shared-lock contention fails quickly and never publishes a partial report.
held_lock="$work/held-operation.lock"
lock_ready="$work/held-operation.ready"
(
  exec 8>"$held_lock"
  flock 8
  : >"$lock_ready"
  sleep 30
) &
lock_holder=$!
for _ in {1..50}; do
  [[ -e "$lock_ready" ]] && break
  sleep 0.02
done
if NIXOS_UPDATE_CHECKER_LOCK="$held_lock" NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT=0.1 \
  run_checker --report "$work/locked-report.json" \
    --candidate-lock "$work/locked-candidate.lock" "$work/repository" \
    >/dev/null 2>&1; then
  echo "Expected lock contention to fail" >&2
  exit 1
fi
[[ ! -e "$work/locked-report.json" ]]

echo "checker fixtures passed"
