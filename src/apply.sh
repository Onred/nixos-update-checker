#!/usr/bin/env bash

set -Eeuo pipefail

action=switch
status_path=${NIXOS_UPDATE_CHECKER_STATUS:-}
temporary_lock=""
started_at=""

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-apply [--boot] REPORT CANDIDATE_LOCK REPOSITORY

Install an update that was built by NixOS Update Checker. The default activates
it immediately; --boot installs it for the next boot. Administrator permission
is required.
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
  write_status failed "The update could not be installed." \
    "Open Progress for technical details."
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
  echo "nixos-update-checker-apply 4.1.8"
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

[[ -f "$repository/flake.nix" ]] || die "The NixOS configuration could not be found."
[[ -f "$repository/flake.lock" ]] || die "The NixOS configuration lock file could not be found."
[[ -f "$report" ]] || die "No built update is ready to install."
[[ -f "$candidate_lock" ]] || die "The saved update information is missing. Refresh and try again."

if ! jq -e --arg repository "$repository" '
  .schemaVersion == 3 and .status == "success"
  and .analysis.mode == "verified"
  and .updatesAvailable == true
  and .repository == $repository
' "$report" >/dev/null; then
  die "This update is not ready to install. Refresh, then build it again."
fi

# Validate the reviewed report before privilege so fixtures can exercise the
# same eligibility rule without performing an installation.
[[ $EUID == 0 ]] || die "Administrator permission is required to install updates."

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
  die "Your system changed since the last refresh. Refresh and try again."

sha256_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

[[ "$expected_working_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
  die "Your NixOS configuration changed since the last refresh. Refresh and try again."
[[ "$expected_candidate_hash" == "$(sha256_file "$candidate_lock")" ]] || \
  die "The saved update is no longer valid. Refresh and build it again."
[[ -e "$expected_candidate" ]] || \
  die "The built update is no longer available. Build it again."

if ! evaluated_candidate=$(nix eval --raw --no-write-lock-file \
  --reference-lock-file "$candidate_lock" \
  "path:$repository#nixosConfigurations.\"$configuration\".config.system.build.toplevel.outPath" \
  2>&1); then
  die "The NixOS configuration could not be checked before installation." "$evaluated_candidate"
fi
[[ "$evaluated_candidate" == "$expected_candidate" ]] || \
  die "Your NixOS configuration changed after the build. Refresh and build the update again."

temporary_lock=$(mktemp "$repository/.flake.lock.nixos-update-checker.XXXXXX")
install -m 0644 "$candidate_lock" "$temporary_lock"
mv -f "$temporary_lock" "$repository/flake.lock"
temporary_lock=""

if ! nixos-rebuild "$action" --flake "path:$repository#$configuration"; then
  die "NixOS could not install the update."
fi

# The profile path unit publishes a fresh report. Removing the old report keeps
# restarted readers from presenting an update that was already installed.
rm -f "$report" "$candidate_lock"

write_status succeeded \
  "$(if [[ "$action" == boot ]]; then echo 'Update installed for next boot'; else echo 'System updated'; fi)" ""
