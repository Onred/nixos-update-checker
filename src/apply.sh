#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-apply REPORT CANDIDATE_LOCK REPOSITORY

Apply the exact candidate lock and system recorded in a verified schema-3
report. This command must run as root.
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi
if [[ ${1:-} == "--version" ]]; then
  echo "nixos-update-checker-apply 4.0.0"
  exit 0
fi
[[ $# == 3 ]] || { usage >&2; exit 2; }

report=$1
candidate_lock=$2
repository=$(readlink -f "$3")

if [[ -n "${NIXOS_UPDATE_CHECKER_LOCK:-}" ]]; then
  exec 9>"$NIXOS_UPDATE_CHECKER_LOCK"
  flock 9
fi

[[ $EUID == 0 ]] || { echo "This command must run as root." >&2; exit 1; }
[[ -f "$repository/flake.nix" ]] || { echo "No flake.nix exists in $repository." >&2; exit 1; }
[[ -f "$repository/flake.lock" ]] || { echo "No flake.lock exists in $repository." >&2; exit 1; }
[[ -f "$report" ]] || { echo "No verified update report exists yet." >&2; exit 1; }
[[ -f "$candidate_lock" ]] || { echo "The reviewed candidate lock is missing." >&2; exit 1; }

if ! jq -e --arg repository "$repository" '
  .schemaVersion == 3 and .status == "success"
  and .analysis.mode == "verified"
  and .inputBaseline.complete == true
  and .updatesAvailable == true
  and .repository == $repository
' "$report" >/dev/null; then
  echo "The report is not a complete, verified update for this repository." >&2
  exit 1
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
[[ "$report_baseline" == "$current_baseline" ]] || {
  echo "The system profile changed after this report was generated. Run Refresh first." >&2
  exit 1
}

sha256_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

[[ "$expected_working_hash" == "$(sha256_file "$repository/flake.lock")" ]] || {
  echo "flake.lock changed after this report was generated. Run Refresh first." >&2
  exit 1
}
[[ "$expected_candidate_hash" == "$(sha256_file "$candidate_lock")" ]] || {
  echo "The saved candidate lock does not match the verified report." >&2
  exit 1
}
[[ -e "$expected_candidate" ]] || {
  echo "The verified system is no longer present in the Nix store. Build it again." >&2
  exit 1
}

evaluated_candidate=$(nix eval --raw --no-write-lock-file \
  --reference-lock-file "$candidate_lock" \
  "path:$repository#nixosConfigurations.\"$configuration\".config.system.build.toplevel.outPath")
[[ "$evaluated_candidate" == "$expected_candidate" ]] || {
  echo "The configuration changed after the verified build. Run Refresh and Build Update again." >&2
  exit 1
}

temporary_lock=$(mktemp "$repository/.flake.lock.nixos-update-checker.XXXXXX")
cleanup() {
  rm -f "$temporary_lock"
}
trap cleanup EXIT
install -m 0644 "$candidate_lock" "$temporary_lock"
mv -f "$temporary_lock" "$repository/flake.lock"

nixos-rebuild switch --flake "path:$repository#$configuration"

# The profile path unit will publish a fresh preview. Removing the old state
# keeps restarted readers from presenting the applied update in the meantime.
rm -f "$report" "$candidate_lock"
