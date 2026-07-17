#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-apply REPORT REPOSITORY

Update the configured flake.lock and switch to the configuration recorded in a
successful update report.
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi
if [[ ${1:-} == "--version" ]]; then
  echo "nixos-update-checker-apply 3.1.4"
  exit 0
fi
[[ $# == 2 ]] || { usage >&2; exit 2; }

report=$1
repository=$(readlink -f "$2")

if [[ -n "${NIXOS_UPDATE_CHECKER_LOCK:-}" ]]; then
  exec 9>"$NIXOS_UPDATE_CHECKER_LOCK"
  flock 9
fi

[[ $EUID == 0 ]] || { echo "This command must run as root." >&2; exit 1; }
[[ -f "$repository/flake.nix" ]] || { echo "No flake.nix exists in $repository." >&2; exit 1; }
[[ -f "$report" ]] || { echo "No successful update report exists yet." >&2; exit 1; }

report_repository=$(jq -er \
  'select(.schemaVersion == 2 and .status == "success" and .inputBaseline.complete == true and .updatesAvailable == true) | .repository' \
  "$report")
configuration=$(jq -er \
  'select(.schemaVersion == 2 and .status == "success" and .inputBaseline.complete == true and .updatesAvailable == true) | .configuration' \
  "$report")
report_baseline=$(jq -er '.system.baselinePath' "$report")
[[ $(readlink -f "$report_repository") == "$repository" ]] || {
  echo "The update report belongs to a different repository." >&2
  exit 1
}

running_system=$(readlink -f "${NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM:-/run/current-system}")
boot_system=$(readlink -f "${NIXOS_UPDATE_CHECKER_BOOT_SYSTEM:-/nix/var/nix/profiles/system}" 2>/dev/null || true)
[[ -n "$boot_system" ]] || boot_system=$running_system
current_baseline=$running_system
if [[ "$boot_system" != "$running_system" ]]; then
  current_baseline=$boot_system
fi
[[ "$report_baseline" == "$current_baseline" ]] || {
  echo "The system profile changed after this report was generated. Run a new check first." >&2
  exit 1
}

nix flake update --flake "path:$repository"
nixos-rebuild switch --flake "path:$repository#$configuration"
