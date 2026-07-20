#!/usr/bin/env bash

set -euo pipefail

checker=${1:-src/checker.sh}
apply=${2:-src/apply.sh}
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
mkdir -p "$work/systems/running" "$work/systems/boot"
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
    NIXOS_UPDATE_CHECKER_FINALIZING="${NIXOS_UPDATE_CHECKER_FINALIZING:-false}" \
    NIXOS_UPDATE_CHECKER_HOSTNAME=fixture \
    NIXOS_UPDATE_CHECKER_LOCK="${NIXOS_UPDATE_CHECKER_LOCK:-}" \
    NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT="${NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT:-30}" \
    NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION=old-nixpkgs-revision \
    FAKE_RUNNING_SYSTEM="$(readlink -f "$work/running-link")" \
    FAKE_BOOT_SYSTEM="$(readlink -f "$work/boot-link")" \
    FAKE_CANDIDATE_SYSTEM="${FAKE_CANDIDATE_SYSTEM_OVERRIDE:-$work/systems/candidate}" \
    FAKE_DECLARED_DERIVER="${FAKE_DECLARED_DERIVER:-/nix/store/different.drv}" \
    FAKE_METADATA_FAILURE="${FAKE_METADATA_FAILURE:-}" \
    FAKE_UNCHANGED_PACKAGES="${FAKE_UNCHANGED_PACKAGES:-}" \
    FAKE_DISCOVERY_FAILURE="${FAKE_DISCOVERY_FAILURE:-}" \
    FAKE_DISCOVERY_BLOCK="${FAKE_DISCOVERY_BLOCK:-}" \
    FAKE_DISCOVERY_MARKER="$work/discovery-blocked" \
    FAKE_INVOCATIONS="$work/nix-invocations" \
    "$checker" --status "$work/status.json" "$@"
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
  (.packages.changes | map(.kind) | index("removed") | not) and
  (.packages.changes | map(.name) | index("unused-option-package") | not) and
  all(.packages.changes[]; .sizeKnown == false) and
  .packages.rebuilds.sizeKnown == false and
  .packages.system.count == 2 and .packages.system.sizeKnown == false and
  ([.packages.changes[].after.versions[]?, .packages.rebuilds.items[].versions[]?]
    | index("unversioned") | not) and
  (.packages.changes[] | select(.name == "firefox") | .confidence) == "confirmed"
' "$report" >/dev/null
if grep -q 'unused-option-package' "$work/nix-invocations"; then
  echo "Preview queried an unconfirmed package-option hint" >&2
  exit 1
fi
if grep -q 'firefox-option-hint' "$work/nix-invocations"; then
  echo "Preview queried an option hint merely because its name matched" >&2
  exit 1
fi
[[ -s "$candidate_lock" ]]
jq -e '
  .schemaVersion == 1 and .state == "succeeded" and
  .operation == "refresh" and .message == "Update check finished"
' "$work/status.json" >/dev/null

# An option-derived package is safe to preview when the same option source
# supplied a package that is proven to exist in the baseline closure.
: >"$work/nix-invocations"
FAKE_DECLARED_DERIVER=/nix/store/boot.drv \
  run_checker --report "$work/active-option-report.json" \
    --candidate-lock "$work/active-option.lock" "$work/repository"
grep -q 'active-option-2.0' "$work/nix-invocations"
if grep -q 'unused-option-package' "$work/nix-invocations"; then
  echo "Preview queried an option source absent from the baseline closure" >&2
  exit 1
fi

# The post-install refresh has its own operation state so the GUI can present
# it as the final phase of installation, even after the GUI restarts.
NIXOS_UPDATE_CHECKER_FINALIZING=true \
  run_checker --report "$work/final-report.json" \
    --candidate-lock "$work/final-candidate.lock" "$work/repository"
jq -e '
  .state == "succeeded" and .operation == "finalize" and
  .message == "Update finished"
' "$work/status.json" >/dev/null

# Configuration errors are terminal for this invocation. They are recorded
# separately and must leave the last successful report and candidate untouched.
report_hash=$(sha256sum "$report")
candidate_hash=$(sha256sum "$candidate_lock")
if FAKE_DISCOVERY_FAILURE=1 run_checker --report "$report" \
  --candidate-lock "$candidate_lock" "$work/repository" >/dev/null 2>&1; then
  echo "Expected invalid configuration discovery to fail" >&2
  exit 1
fi
[[ "$report_hash" == "$(sha256sum "$report")" ]]
[[ "$candidate_hash" == "$(sha256sum "$candidate_lock")" ]]
jq -e '
  .state == "failed" and .operation == "refresh" and
  .message == "Could not read packages from your NixOS configuration."
' "$work/status.json" >/dev/null

# Cancellation also preserves the published state and reaches a terminal
# operation status instead of leaving the GUI stuck on "running".
rm -f "$work/discovery-blocked"
FAKE_DISCOVERY_BLOCK=1 run_checker --report "$report" \
  --candidate-lock "$candidate_lock" "$work/repository" >/dev/null 2>&1 &
cancelled_checker=$!
for _ in {1..100}; do
  [[ -e "$work/discovery-blocked" ]] && break
  sleep 0.02
done
[[ -e "$work/discovery-blocked" ]] || {
  echo "Cancellation fixture never reached package discovery" >&2
  exit 1
}
checker_children=$(<"/proc/$cancelled_checker/task/$cancelled_checker/children")
checker_process=${checker_children%% *}
[[ -n "$checker_process" ]] || {
  echo "Could not locate the cancellable checker process" >&2
  exit 1
}
kill "$checker_process"
cancel_status=0
wait "$cancelled_checker" || cancel_status=$?
[[ $cancel_status == 143 ]]
[[ "$report_hash" == "$(sha256sum "$report")" ]]
[[ "$candidate_hash" == "$(sha256sum "$candidate_lock")" ]]
jq -e '.state == "cancelled" and .operation == "refresh"' \
  "$work/status.json" >/dev/null

# Garbage collection or cache misses must never turn unknown paths into
# removals, inferred versions, or known closure sizes.
FAKE_METADATA_FAILURE=1 \
  run_checker --report "$work/cache-miss-report.json" \
    --candidate-lock "$work/cache-miss.lock" "$work/repository"
jq -e '
  .analysis.mode == "preview" and
  .analysis.candidateClosureComplete == false and
  .build.candidateClosureBytes == null and
  .build.closureDeltaBytes == null and
  (.packages.changes | map(.kind) | index("removed") | not) and
  all(.packages.changes[]; .confidence == "configured" and .sizeKnown == false) and
  .packages.rebuilds.sizeKnown == false
' "$work/cache-miss-report.json" >/dev/null

# Moving unchanged configuration between modules may change the system
# derivation without changing packages. Same-name option hints must not turn
# into speculative rebuilds when their exact paths are absent from baseline.
: >"$work/nix-invocations"
FAKE_UNCHANGED_PACKAGES=1 \
  run_checker --report "$work/config-only-report.json" \
    --candidate-lock "$work/config-only.lock" "$work/repository"
jq -e '
  (.packages.changes | length) == 0 and
  .packages.rebuilds.count == 0
' "$work/config-only-report.json" >/dev/null
if grep -q 'firefox-option-hint' "$work/nix-invocations"; then
  echo "Configuration-only preview queried a same-name option hint" >&2
  exit 1
fi

# An identical candidate is already exact. It must short-circuit metadata and
# dry-run work and publish an empty verified package comparison.
: >"$work/nix-invocations"
FAKE_CANDIDATE_SYSTEM_OVERRIDE="$(readlink -f "$work/running-link")" \
  run_checker --report "$work/identical-report.json" \
    --candidate-lock "$work/identical.lock" "$work/repository"
jq -e '
  .analysis.mode == "verified" and
  .analysis.candidateClosureComplete == true and
  .system.baselinePath == .system.candidate and
  (.packages.changes | length) == 0 and
  .packages.rebuilds.count == 0 and
  .build.closureDeltaBytes == 0 and .build.sizeKnown == true
' "$work/identical-report.json" >/dev/null
if grep -Eq 'config show|build .*--dry-run|derivation show' "$work/nix-invocations"; then
  echo "Identical candidate performed speculative preview work" >&2
  exit 1
fi

# Building is explicit and replaces the preview with an exact closure report.
# The latest preview/verified pair remains available for detection diagnostics.
run_checker --build --report "$report" --candidate-lock "$candidate_lock" \
  --preview-snapshot "$work/last-build-preview.json" \
  --verified-snapshot "$work/last-build-verified.json" "$work/repository"
jq -e '
  .schemaVersion == 3 and .status == "success" and
  .analysis.mode == "verified" and
  .analysis.candidateClosureComplete == true and
  .inputBaseline.complete == false and
  .build.sizeKnown == true and
  (.packages.changes[] | select(.name == "added") | .deltaBytes) == 50 and
  (.packages.changes[] | select(.name == "removed") | .deltaBytes) == -30 and
  .packages.rebuilds.count == 1 and
  .packages.rebuilds.deltaBytes == 1 and
  .packages.system.count == 2 and .packages.system.deltaBytes == 2 and
  (.analysis.previewComparison.missedByPreview | index("removed")) != null
' "$report" >/dev/null
jq -e '.analysis.mode == "preview"' "$work/last-build-preview.json" >/dev/null
jq -e '
  .analysis.mode == "verified" and
  .analysis.previewComparison.verifiedCount >= .analysis.previewComparison.previewCount
' "$work/last-build-verified.json" >/dev/null
jq -e '.state == "succeeded" and .operation == "build"' "$work/status.json" >/dev/null

# Incomplete historical source data must not reject an exact, verified build.
# An unprivileged invocation reaches the permission check only after the same
# report eligibility check used by the root service has accepted the report.
if ((EUID != 0)); then
  if NIXOS_UPDATE_CHECKER_STATUS="$work/apply-status.json" \
    "$apply" "$report" "$candidate_lock" "$work/repository" >/dev/null 2>&1; then
    echo "Expected the unprivileged apply fixture to stop at its permission check" >&2
    exit 1
  fi
  jq -e '
    .state == "failed" and
    .message == "Administrator permission is required to install updates."
  ' "$work/apply-status.json" >/dev/null
fi

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
