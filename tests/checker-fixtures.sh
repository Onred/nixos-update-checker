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
    NIXOS_UPDATE_CHECKER_LOCK="${NIXOS_UPDATE_CHECKER_LOCK:-}" \
    NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT="${NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT:-30}" \
    FAKE_WORK_DIRECTORY="$work" \
    FAKE_VERIFY_PARALLEL="${FAKE_VERIFY_PARALLEL:-}" \
    FAKE_VERIFY_WORKERS="${FAKE_VERIFY_WORKERS:-}" \
    FAKE_FAIL_PATH_INFO="${FAKE_FAIL_PATH_INFO:-}" \
    NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION=old-nixpkgs-revision \
    FAKE_RUNNING_SYSTEM="$(readlink -f "$work/running-link")" \
    FAKE_BOOT_SYSTEM="$(readlink -f "$work/boot-link")" \
    FAKE_CANDIDATE_SYSTEM="${FAKE_CANDIDATE_SYSTEM_OVERRIDE:-$work/systems/candidate}" \
    FAKE_DECLARED_DERIVER="$declared" \
    "$checker" --report "$work/report-$name.json" "$work/repository"
}

# No system-bound lock: recover nixpkgs only and mark the input history partial.
FAKE_VERIFY_PARALLEL=1
FAKE_VERIFY_WORKERS=1
run_check incomplete /nix/store/different.drv "$work/state/incomplete.json"
unset FAKE_VERIFY_PARALLEL
unset FAKE_VERIFY_WORKERS
[[ $(<"$work/worker-maximum") == 8 ]]
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
  .build.maxJobs == 32 and
  .build.coresPerJob == 1 and
  .build.workerCount == 8 and
  .build.workerDerivations == 9 and
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

# Root inputs may follow another root input instead of naming a node directly.
jq '.lock.nodes.tool.locked.rev = "tool-old"' "$work/state/system-lock.json" \
  >"$work/state/system-lock-old-tool.json"
run_check followed-input /nix/store/different.drv "$work/state/system-lock-old-tool.json"
jq -e '
  ([.inputs[] | select(.name == "tool")][0] |
    .before.revision == "tool-old" and .after.revision == "tool-current") and
  ([.inputs[] | select(.name == "followed-tool")][0] |
    .before.revision == "tool-old" and .after.revision == "tool-current")
' "$work/report-followed-input.json" >/dev/null

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

# Equal systems need only one closure query.
: >"$work/path-info-calls"
FAKE_CANDIDATE_SYSTEM_OVERRIDE="$work/systems/boot"
run_check equal-system /nix/store/boot.drv "$work/state/equal-lock.json"
unset FAKE_CANDIDATE_SYSTEM_OVERRIDE
[[ $(wc -l <"$work/path-info-calls") == 1 ]]
jq -e '
  .system.baselinePath == .system.candidate and
  (.packages.changes | length) == 0 and
  .packages.rebuilds.count == 0
' "$work/report-equal-system.json" >/dev/null

# Either parallel closure query can fail without leaving a child or partial report.
for side in baseline candidate; do
  rm -f "$work"/path-info-*.pid
  FAKE_FAIL_PATH_INFO=$side
  if run_check "failure-$side" /nix/store/boot.drv "$work/state/failure-$side.json" \
    >/dev/null 2>&1; then
    echo "Expected the $side closure query to fail" >&2
    exit 1
  fi
  unset FAKE_FAIL_PATH_INFO
  jq -e --arg side "$side" '
    .schemaVersion == 2 and .status == "error" and
    (has("packages") | not) and
    (.error.diagnostics | ascii_downcase | contains($side))
  ' "$work/report-failure-$side.json" >/dev/null
  for pid_file in "$work"/path-info-*.pid; do
    [[ -e "$pid_file" ]] || continue
    if kill -0 "$(<"$pid_file")" 2>/dev/null; then
      echo "Closure query process was left running: $(<"$pid_file")" >&2
      exit 1
    fi
  done
done

# Lock contention fails quickly so systemd can retry instead of waiting forever.
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
[[ -e "$lock_ready" ]]
if NIXOS_UPDATE_CHECKER_LOCK="$held_lock" NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT=0.1 \
  run_check lock-contention /nix/store/boot.drv "$work/state/lock-contention.json" \
  >/dev/null 2>&1; then
  echo "Expected lock contention to fail" >&2
  exit 1
fi
kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
lock_holder=""
[[ ! -e "$work/report-lock-contention.json" ]]

echo "checker fixtures passed"
