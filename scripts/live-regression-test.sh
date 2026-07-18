#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: live-regression-test.sh [OPTIONS]

Create a disposable old-content NixOS generation, remove every other system
generation, garbage-collect unreachable store paths, and run the update checker.

Exactly one old-lock source is required:
  --old-lock PATH    Use an existing older flake.lock.
  --old-ref REF      Read flake.lock from a Git revision in the config repository.

Options:
  --config PATH      NixOS flake directory (default: $HOME/nixos)
  --host NAME        nixosConfigurations name (default: current hostname)
  --updater-input N  Direct updater input name (default: nixos-update-checker)
  --yes              Skip the destructive confirmation prompt
  --help             Show this help

The old lock must retain the same updater input as the current lock. On success,
the old lock and old-content generation remain active so the GUI can exercise
Build Update and Update. A copy of the original lock is retained for recovery.
EOF
}

config_directory=${CONFIG_DIR:-$HOME/nixos}
host=${HOST:-$(hostname)}
updater_input=${UPDATER_INPUT:-nixos-update-checker}
old_lock_source=""
old_ref=""
assume_yes=false

while (($#)); do
  case "$1" in
    --config)
      config_directory=${2:?Missing path after --config}
      shift 2
      ;;
    --host)
      host=${2:?Missing name after --host}
      shift 2
      ;;
    --updater-input)
      updater_input=${2:?Missing name after --updater-input}
      shift 2
      ;;
    --old-lock)
      old_lock_source=${2:?Missing path after --old-lock}
      shift 2
      ;;
    --old-ref)
      old_ref=${2:?Missing revision after --old-ref}
      shift 2
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $EUID != 0 ]] || {
  echo "Run this script as your desktop user, not as root." >&2
  exit 1
}
[[ -z "$old_lock_source" || -z "$old_ref" ]] || {
  echo "Use either --old-lock or --old-ref, not both." >&2
  exit 2
}
[[ -n "$old_lock_source" || -n "$old_ref" ]] || {
  echo "An older lock is required through --old-lock or --old-ref." >&2
  exit 2
}

for command in git install jq nix nix-env nix-store nixos-rebuild readlink sudo systemctl; do
  command -v "$command" >/dev/null || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

config_directory=$(readlink -f "$config_directory")
[[ -f "$config_directory/flake.nix" && -f "$config_directory/flake.lock" ]] || {
  echo "No flake.nix and flake.lock were found in $config_directory." >&2
  exit 1
}

state_root=${XDG_STATE_HOME:-$HOME/.local/state}/nixos-update-checker
run_directory="$state_root/live-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_directory"
current_lock="$run_directory/flake.lock.current"
old_lock="$run_directory/flake.lock.old"
install -m 0644 "$config_directory/flake.lock" "$current_lock"

if [[ -n "$old_lock_source" ]]; then
  old_lock_source=$(readlink -f "$old_lock_source")
  [[ -f "$old_lock_source" ]] || {
    echo "Older lock does not exist: $old_lock_source" >&2
    exit 1
  }
  install -m 0644 "$old_lock_source" "$old_lock"
else
  git -C "$config_directory" show "$old_ref:flake.lock" >"$old_lock"
fi

jq -e '.nodes and .root and .version' "$current_lock" "$old_lock" >/dev/null
cmp -s "$current_lock" "$old_lock" && {
  echo "The selected older lock is identical to the current lock." >&2
  exit 1
}

direct_locked() {
  local lock=$1
  jq -cer --arg input "$updater_input" '
    .root as $root |
    .nodes[$root].inputs[$input] as $reference |
    select(($reference | type) == "string") |
    .nodes[$reference].locked
  ' "$lock"
}

current_updater=$(direct_locked "$current_lock") || {
  echo "Could not resolve direct input '$updater_input' in the current lock." >&2
  exit 1
}
old_updater=$(direct_locked "$old_lock") || {
  echo "Could not resolve direct input '$updater_input' in the older lock." >&2
  exit 1
}
[[ "$current_updater" == "$old_updater" ]] || {
  echo "The older lock would also change '$updater_input'." >&2
  echo "Prepare an old lock that keeps the current updater while rolling package inputs back." >&2
  exit 1
}

echo "Evaluating the older lock before making system changes..."
old_system=$(nix eval --raw --no-write-lock-file --reference-lock-file "$old_lock" \
  "path:$config_directory#nixosConfigurations.\"$host\".config.system.build.toplevel.outPath")
running_system=$(readlink -f /run/current-system)
[[ "$old_system" != "$running_system" ]] || {
  echo "The older lock evaluates to the currently running system; it will not test an update." >&2
  exit 1
}

cat <<EOF

This test will:
  1. replace $config_directory/flake.lock with the selected older lock;
  2. run nixos-rebuild switch for configuration $host;
  3. delete every non-current system generation, including newer generations;
  4. garbage-collect every unreachable store path;
  5. run the unrestricted manual update preview.

Original lock backup:
  $current_lock

The system will remain on the old-content generation afterward so the GUI can
exercise Build Update and Update.
EOF

if [[ "$assume_yes" != true ]]; then
  read -r -p 'Type DELETE GENERATIONS to continue: ' confirmation
  [[ "$confirmation" == "DELETE GENERATIONS" ]] || {
    echo "Cancelled."
    exit 1
  }
fi

sudo -v
for unit in nixos-update-checker-build.service nixos-update-checker-apply.service; do
  if systemctl is-active --quiet "$unit"; then
    echo "$unit is active. Let it finish before running this test." >&2
    exit 1
  fi
done

timer_was_active=false
path_was_active=false
systemctl is-active --quiet nixos-update-checker.timer && timer_was_active=true
systemctl is-active --quiet nixos-update-checker.path && path_was_active=true
success=false
lock_changed=false
background_masked=false

restore_lock() {
  local temporary_lock
  temporary_lock=$(mktemp "$config_directory/.flake.lock.live-test.XXXXXX")
  install -m 0644 "$current_lock" "$temporary_lock"
  mv -f "$temporary_lock" "$config_directory/flake.lock"
}

cleanup() {
  local status=$?
  if [[ "$background_masked" == true ]]; then
    sudo systemctl unmask --runtime nixos-update-checker-background.service >/dev/null 2>&1 || true
  fi
  if [[ "$timer_was_active" == true ]]; then
    sudo systemctl start nixos-update-checker.timer >/dev/null 2>&1 || true
  fi
  if [[ "$path_was_active" == true ]]; then
    sudo systemctl start nixos-update-checker.path >/dev/null 2>&1 || true
  fi
  if [[ "$success" != true && "$lock_changed" == true ]]; then
    restore_lock || true
    echo "The test failed; the original flake.lock was restored." >&2
    echo "The active system may still need: sudo nixos-rebuild switch --flake path:$config_directory#$host" >&2
  fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo systemctl stop nixos-update-checker.timer nixos-update-checker.path \
  nixos-update-checker.service nixos-update-checker-background.service 2>/dev/null || true
sudo systemctl mask --runtime nixos-update-checker-background.service >/dev/null
background_masked=true

temporary_lock=$(mktemp "$config_directory/.flake.lock.live-test.XXXXXX")
install -m 0644 "$old_lock" "$temporary_lock"
mv -f "$temporary_lock" "$config_directory/flake.lock"
lock_changed=true

echo "Building and switching to the old-content generation..."
sudo nixos-rebuild switch --flake "path:$config_directory#$host"

installed_version=$(/run/current-system/sw/bin/nixos-update-checker-service --version 2>/dev/null || true)
[[ "$installed_version" == *"4.1.6"* ]] || {
  echo "The test generation does not contain updater 4.1.6: $installed_version" >&2
  echo "Keep the current updater input in the older lock and try again." >&2
  exit 1
}

sudo systemctl stop nixos-update-checker.timer nixos-update-checker.path \
  nixos-update-checker-background.service 2>/dev/null || true

echo "Deleting all non-current NixOS generations..."
sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations old

echo "Garbage-collecting unreachable store paths..."
sudo nix-store --gc

sudo systemctl unmask --runtime nixos-update-checker-background.service >/dev/null
background_masked=false

echo "Running the unrestricted manual preview..."
systemctl start nixos-update-checker.service

report=/var/lib/nixos-update-checker/report.json
jq -e '
  .schemaVersion == 3 and .status == "success" and
  .inputBaseline.complete == true and
  .system.baselinePath == .system.running.path and
  .system.candidate != .system.baselinePath and
  (all(.packages.changes[]; .confidence != "inferred")) and
  (all(.packages.rebuilds.items[]; .confidence != "inferred")) and
  (if .analysis.mode == "preview" then
     .analysis.candidateClosureComplete == false and
     .build.candidateClosureBytes == null and
     .build.closureDeltaBytes == null and
     (.packages.changes | map(.kind) | index("removed") | not) and
     all(.packages.changes[]; .sizeKnown == false) and
     .packages.rebuilds.sizeKnown == false
   else
     .analysis.mode == "verified" and
     .analysis.candidateClosureComplete == true and .build.sizeKnown == true
   end)
' "$report" >/dev/null

jq '{
  generatedAt,
  mode: .analysis.mode,
  inputChanges: (.inputs | length),
  packageChanges: (.packages.changes | length),
  rebuilds: .packages.rebuilds.count,
  localBuilds: .buildPlan.localBuildCount,
  baseline: .system.baselinePath,
  candidate: .system.candidate
}' "$report"

success=true

cat <<EOF

Live regression setup completed successfully.

Open the app from your desktop or run:
  nixos-update-checker

The old lock intentionally remains at:
  $config_directory/flake.lock

The reviewed GUI flow should now be:
  Build Update -> Update

If you want to abandon the test instead, restore the saved lock and rebuild:
  install -m 0644 '$current_lock' '$config_directory/flake.lock'
  sudo nixos-rebuild switch --flake 'path:$config_directory#$host'

After either recovery path succeeds, the backup directory can be removed:
  $run_directory
EOF
