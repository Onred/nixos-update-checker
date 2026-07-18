#!/usr/bin/env bash

set -Eeuo pipefail

action=switch
status_path=${NIXOS_UPDATE_CHECKER_STATUS:-}
temporary_lock=""
started_at=""

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-apply [--boot] REPORT CANDIDATE_LOCK REPOSITORY

Apply the exact candidate recorded in a verified schema-3 report. The default
activates it immediately; --boot installs it as the default for the next boot.
This command must run as root.
EOF
}

write_status() {
  local state=$1
  local message=${2:-}
  local diagnostics=${3:-}
  [[ -n "$status_path" ]] || return
  local status_file
  status_file=$(mktemp "$(dirname "$status_path")/.operation-status.XXXXXX")
  jq -n \
    --arg state "$state" \
    --arg operation "apply-$action" \
    --arg startedAt "$started_at" \
    --arg updatedAt "$(date --iso-8601=seconds)" \
    --arg message "$message" \
    --arg diagnostics "$diagnostics" '{
      schemaVersion: 1,
      state: $state,
      operation: $operation,
      startedAt: (if $startedAt == "" then null else $startedAt end),
      updatedAt: $updatedAt,
      message: $message,
      diagnostics: $diagnostics
    }' >"$status_file"
  chmod 0644 "$status_file"
  mv -f "$status_file" "$status_path"
}

die() {
  local message=$1
  local diagnostics=${2:-}
  echo "$message" >&2
  [[ -z "$diagnostics" ]] || echo "$diagnostics" >&2
  write_status failed "$message" "$diagnostics"
  exit 1
}

cleanup() {
  [[ -z "$temporary_lock" ]] || rm -f "$temporary_lock"
}

cancel() {
  trap - TERM INT
  write_status cancelled "Operation cancelled" ""
  exit 143
}

unexpected_error() {
  local exit_status=$?
  trap - ERR
  write_status failed "Operation failed unexpectedly." \
    "See the system journal for the command that failed."
  exit "$exit_status"
}

trap cleanup EXIT
trap cancel TERM INT
trap unexpected_error ERR

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi
if [[ ${1:-} == "--version" ]]; then
  echo "nixos-update-checker-apply 4.1.1"
  exit 0
fi
if [[ ${1:-} == "--boot" ]]; then
  action=boot
  shift
fi
[[ $# == 3 ]] || { usage >&2; exit 2; }

report=$1
candidate_lock=$2
repository=$(readlink -f "$3")

if [[ -n "${NIXOS_UPDATE_CHECKER_LOCK:-}" ]]; then
  exec 9>"$NIXOS_UPDATE_CHECKER_LOCK"
  flock 9
fi

started_at=$(date --iso-8601=seconds)
write_status running \
  "$(if [[ "$action" == boot ]]; then echo 'Installing update for next boot'; else echo 'Applying update now'; fi)" ""

[[ $EUID == 0 ]] || die "This command must run as root."
[[ -f "$repository/flake.nix" ]] || die "No flake.nix exists in $repository."
[[ -f "$repository/flake.lock" ]] || die "No flake.lock exists in $repository."
[[ -f "$report" ]] || die "No verified update report exists yet."
[[ -f "$candidate_lock" ]] || die "The reviewed candidate lock is missing."

if ! jq -e --arg repository "$repository" '
  .schemaVersion == 3 and .status == "success"
  and .analysis.mode == "verified"
  and .inputBaseline.complete == true
  and .updatesAvailable == true
  and .repository == $repository
' "$report" >/dev/null; then
  die "The report is not a complete, verified update for this repository."
fi

configuration=$(jq -er '.configuration' "$report")
report_baseline=$(jq -er '.system.baselinePath' "$report")
expected_candidate=$(jq -er '.system.candidate' "$report")
expected_working_hash=$(jq -er '.candidate.workingLockHash' "$report")
expected_candidate_hash=$(jq -er '.candidate.lockHash' "$report")

running_system=$(readlink -f "${NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM:-/run/current-system}")
boot_system=$(readlink -f \
  "${NIXOS_UPDATE_CHECKER_BOOT_SYSTEM:-/nix/var/nix/profiles/system}" 2>/dev/null || true)
[[ -n "$boot_system" ]] || boot_system=$running_system
current_baseline=$running_system
if [[ "$boot_system" != "$running_system" ]]; then
  current_baseline=$boot_system
fi
[[ "$report_baseline" == "$current_baseline" ]] || \
  die "The system profile changed after this report was generated. Run Refresh first."

sha256_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

[[ "$expected_working_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
  die "flake.lock changed after this report was generated. Run Refresh first."
[[ "$expected_candidate_hash" == "$(sha256_file "$candidate_lock")" ]] || \
  die "The saved candidate lock does not match the verified report."
[[ -e "$expected_candidate" ]] || \
  die "The verified system is no longer present in the Nix store. Build it again."

if ! evaluated_candidate=$(nix eval --raw --no-write-lock-file \
  --reference-lock-file "$candidate_lock" \
  "path:$repository#nixosConfigurations.\"$configuration\".config.system.build.toplevel.outPath" \
  2>&1); then
  die "Could not re-evaluate the verified configuration." "$evaluated_candidate"
fi
[[ "$evaluated_candidate" == "$expected_candidate" ]] || \
  die "The configuration changed after the verified build. Run Refresh and Build Update again."

temporary_lock=$(mktemp "$repository/.flake.lock.nixos-update-checker.XXXXXX")
install -m 0644 "$candidate_lock" "$temporary_lock"
mv -f "$temporary_lock" "$repository/flake.lock"
temporary_lock=""

if ! nixos-rebuild "$action" --flake "path:$repository#$configuration"; then
  die "nixos-rebuild $action failed."
fi

write_status succeeded \
  "$(if [[ "$action" == boot ]]; then echo 'Update installed for next boot'; else echo 'System updated'; fi)" ""

# The profile path unit publishes a fresh report. Removing the old report keeps
# restarted readers from presenting an update that was already installed.
rm -f "$report" "$candidate_lock"
