#!/usr/bin/env bash

set -euo pipefail

checker=${1:-src/checker.sh}
project=$(readlink -f "$(dirname "$0")/..")
fixtures="$project/tests/fixtures"
work=$(mktemp -d -t nixos-update-checker-test.XXXXXX)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/repository" "$work/profiles" "$work/state"
install -m 0644 "$fixtures/flake.nix" "$work/repository/flake.nix"
install -m 0644 "$fixtures/flake.lock" "$work/repository/flake.lock"
mkdir -p "$work/systems/running" "$work/systems/boot" "$work/systems/candidate"
ln -s "$work/systems/running" "$work/profiles/system-38-link"
ln -s "$work/systems/boot" "$work/profiles/system-39-link"
ln -s "$work/systems/running" "$work/running-link"
ln -s "$work/systems/running" "$work/boot-link"

run_check() {
  local name=$1
  local declared=$2
  local state=$3
  env \
    PATH="$fixtures/bin:$PATH" \
    NIXOS_UPDATE_CHECKER_FIXTURES="$fixtures" \
    NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM="$work/running-link" \
    NIXOS_UPDATE_CHECKER_BOOT_SYSTEM="$work/boot-link" \
    NIXOS_UPDATE_CHECKER_PROFILE_DIRECTORY="$work/profiles" \
    NIXOS_UPDATE_CHECKER_STATE="$state" \
    NIXOS_UPDATE_CHECKER_HOSTNAME=fixture \
    NIXOS_UPDATE_CHECKER_CPU_LIST=0-31 \
    NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION=old-nixpkgs-revision \
    FAKE_RUNNING_SYSTEM="$(readlink -f "$work/running-link")" \
    FAKE_BOOT_SYSTEM="$(readlink -f "$work/boot-link")" \
    FAKE_CANDIDATE_SYSTEM="$work/systems/candidate" \
    FAKE_DECLARED_DERIVER="$declared" \
    "$checker" --report "$work/report-$name.json" "$work/repository"
}

# No system-bound lock: recover nixpkgs only and mark the input history partial.
run_check incomplete /nix/store/different.drv "$work/state/incomplete.json"
jq -e '
  .schemaVersion == 2 and
  .inputBaseline == {
    source: "runningNixpkgsFallback",
    complete: false,
    system: .inputBaseline.system
  } and
  .system.running.generation == 38 and
  .system.boot.generation == 38 and
  .system.baseline == "running" and
  .system.readyForBoot == false and
  .build.logicalCpus == 32 and
  .build.workerBudget == 32 and
  .build.maxJobs == 5 and
  .build.coresPerJob == 6 and
  (.inputs | map(select(
    .name == "nixpkgs" and
    .before.revision == "old-nixpkgs-revision" and
    .after.revision == "new-nixpkgs-revision"
  )) | length) == 1 and
  (.packages.changes[] | select(.name == "firefox") | .deltaBytes) == 0 and
  (.packages.changes[] | select(.name == "added") | .deltaBytes) == 50 and
  (.packages.changes[] | select(.name == "removed") | .deltaBytes) == -30 and
  (.packages.changes[] | select(.name == "multi") |
    .before.versions == ["1", "2"] and
    .after.versions == ["2", "3", "4"] and
    .deltaBytes == 20) and
  .packages.rebuilds.count == 1 and
  .packages.rebuilds.deltaBytes == 1 and
  (.packages.rebuilds.items[0] | has("paths") | not)
' "$work/report-incomplete.json" >/dev/null

# A newer default profile is the baseline for both rebuild boot and an older boot.
ln -sfn "$work/systems/boot" "$work/boot-link"
run_check pending-boot /nix/store/boot.drv "$work/state/system-lock.json"
jq -e '
  .inputBaseline.source == "workingConfiguration" and
  .inputBaseline.complete == true and
  .system.running.generation == 38 and
  .system.boot.generation == 39 and
  .system.baseline == "boot" and
  .system.readyForBoot == true
' "$work/report-pending-boot.json" >/dev/null

# If the working configuration moves on, reuse only the lock bound to that system.
run_check manual-old /nix/store/different.drv "$work/state/system-lock.json"
jq -e '
  .inputBaseline.source == "savedSystemLock" and
  .inputBaseline.complete == true and
  .system.baseline == "boot" and
  .system.readyForBoot == true
' "$work/report-manual-old.json" >/dev/null

# Once switched, the same profile becomes the running baseline.
ln -sfn "$work/systems/boot" "$work/running-link"
run_check switch /nix/store/boot.drv "$work/state/switch-lock.json"
jq -e '
  .inputBaseline.source == "workingConfiguration" and
  .system.running.generation == 39 and
  .system.boot.generation == 39 and
  .system.baseline == "running" and
  .system.readyForBoot == false
' "$work/report-switch.json" >/dev/null

echo "checker fixtures passed"
