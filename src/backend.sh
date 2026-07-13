#!/usr/bin/env bash

set -Eeuo pipefail

# Temporary CLI backend for the future graphical update checker.

usage() {
  cat <<'EOF'
Usage: check-nixos-updates [OPTIONS] [REPOSITORY]

Resolve a candidate flake.lock without changing the repository, report
generation/configuration state, compare visible package lists, and optionally
build the candidate system closure.

Options:
  --host HOST    NixOS configuration to inspect (default: nixos)
  --build        Build the candidate toplevel and run nix store diff-closures
  --source-only  Skip package-version inspection after checking source state
  --json         Emit a versioned machine-readable report on stdout
  --debug        Show raw paths, manifests, diffs, and command diagnostics
  --no-limit     Disable the default CPU, process, and I/O limits
  --cpu-quota PERCENT
                 Override the default 25% CPU quota
  --version      Print the backend version
  -h, --help     Show this help

The script never writes the repository's flake.lock. The --build option can
still download or compile packages into the Nix store.

By default, the command uses systemd-run --user with CPUQuota=25%, Nice=19,
and idle I/O scheduling. It waits for completion and keeps output attached to
the terminal, so it is also suitable for use from a user service or timer.

The CPU quota applies to this script and its Nix client evaluations. Nix daemon
build workers started by --build are outside that scope.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

host="${NIXOS_UPDATE_CHECKER_HOST:-nixos}"
backend_version="0.1.0"
schema_version=1
build_closure=false
inspect_packages=true
debug=false
output_format="human"
limit_resources=true
cpu_quota="${NIXOS_UPDATE_CHECKER_DEFAULT_CPU_QUOTA:-25%}"
repo="."
original_args=("$@")

while (($# > 0)); do
  case "$1" in
    --host)
      (($# >= 2)) || die "--host requires a value"
      host="$2"
      shift 2
      ;;
    --build)
      build_closure=true
      shift
      ;;
    --source-only)
      inspect_packages=false
      shift
      ;;
    --debug)
      debug=true
      shift
      ;;
    --json)
      output_format="json"
      shift
      ;;
    --no-limit)
      limit_resources=false
      shift
      ;;
    --background)
      # Backward-compatible alias; resource limiting is now the default.
      limit_resources=true
      shift
      ;;
    --cpu-quota)
      (($# >= 2)) || die "--cpu-quota requires a percentage such as 25%"
      [[ "$2" =~ ^[1-9][0-9]*%$ ]] || die "--cpu-quota must be a positive percentage such as 25%"
      cpu_quota="$2"
      limit_resources=true
      shift 2
      ;;
    --version)
      printf 'check-nixos-updates %s (JSON schema %d)\n' "$backend_version" "$schema_version"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# <= 1)) || die "only one repository path may be supplied"
      repo="${1:-.}"
      shift
      ;;
    -* )
      die "unknown option: $1"
      ;;
    *)
      [[ "$repo" == "." ]] || die "only one repository path may be supplied"
      repo="$1"
      shift
      ;;
  esac
done

if [[ "$output_format" == "json" && "$build_closure" == true ]]; then
  die "--json and --build cannot be combined yet"
fi

if [[ "$limit_resources" == true && "${NIXOS_UPDATE_CHECKER_IN_SCOPE:-}" != "1" ]]; then
  command -v systemd-run >/dev/null || die "default resource limiting requires systemd-run; use --no-limit to opt out"
  command -v ionice >/dev/null || die "default resource limiting requires ionice; use --no-limit to opt out"
  command -v nice >/dev/null || die "default resource limiting requires nice; use --no-limit to opt out"
  command -v bash >/dev/null || die "bash is not available"

  script_path=$(realpath "$0")
  ionice_path=$(command -v ionice)
  nice_path=$(command -v nice)
  bash_path=$(command -v bash)
  exec systemd-run \
    --user \
    --scope \
    --collect \
    --quiet \
    --same-dir \
    --description="NixOS update check" \
    --property="CPUQuota=$cpu_quota" \
    --setenv=NIXOS_UPDATE_CHECKER_IN_SCOPE=1 \
    --setenv="NIXOS_UPDATE_CHECKER_CPU_QUOTA=$cpu_quota" \
    "$ionice_path" -c 3 \
    "$nice_path" -n 19 \
    "$bash_path" "$script_path" "${original_args[@]}"
fi

command -v nix >/dev/null || die "nix is not available"
command -v jq >/dev/null || die "jq is not available"

repo=$(realpath "$repo")
[[ -f "$repo/flake.nix" ]] || die "not a flake directory: $repo"
[[ -f "$repo/flake.lock" ]] || die "flake.lock is required as the current baseline"

cd "$repo"

tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

human_output="$tmpdir/human-output.log"
if [[ "$output_format" == "json" ]]; then
  exec 3>&1
  exec > "$human_output"
fi

candidate_lock="$tmpdir/flake.lock"
installable=".#nixosConfigurations.${host}.config.system.build.toplevel"
configuration=".#nixosConfigurations.${host}"
manifest="${configuration}.config.programs.nixos-update-checker.manifest"

echo "NixOS update check ($host)"
if [[ "${NIXOS_UPDATE_CHECKER_IN_SCOPE:-}" == "1" ]]; then
  echo "  resources: CPU ${NIXOS_UPDATE_CHECKER_CPU_QUOTA} max, nice 19, idle I/O"
else
  echo "  resources: unlimited"
fi

if [[ "$debug" == true ]]; then
  echo "  repository: $repo"
  echo "  temporary:  $tmpdir"
fi

if command -v git >/dev/null && git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
  if [[ "$debug" == true ]]; then
    echo
    echo "[debug] Git state (informational only):"
    git -C "$repo" status --short --branch
  fi
fi

before_lock_hash=$(sha256sum "$repo/flake.lock" | cut -d ' ' -f 1)

resolve_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    readlink -f "$path"
  fi
}

generation_name() {
  local target="$1"
  local link resolved

  for link in /nix/var/nix/profiles/system-*-link; do
    [[ -e "$link" || -L "$link" ]] || continue
    resolved=$(readlink -f "$link" 2>/dev/null || true)
    if [[ "$resolved" == "$target" ]]; then
      basename "$link"
      return
    fi
  done

  echo "unknown"
}

get_deriver() {
  local label="$1"
  local path="$2"
  local error_file="$tmpdir/${label}.deriver.stderr"

  [[ -n "$path" ]] || return 0

  if nix path-info --derivation "$path" 2>"$error_file"; then
    return 0
  fi

  echo "WARNING: could not query the deriver for $label ($path)" >&2
  sed 's/^/  /' "$error_file" >&2
}

running_system=$(resolve_path /run/current-system)
boot_system=$(resolve_path /nix/var/nix/profiles/system)
running_generation=$(generation_name "${running_system:-}")
boot_generation=$(generation_name "${boot_system:-}")
reboot_pending_json=false

echo
echo "System"
printf '  generation:     %s\n' "$running_generation"

if [[ -n "$running_system" && -n "$boot_system" ]]; then
  if [[ "$running_system" == "$boot_system" ]]; then
    echo "  reboot pending: no"
  else
    reboot_pending_json=true
    printf '  reboot pending: yes (%s)\n' "$boot_generation"
  fi
fi

if [[ "$debug" == true ]]; then
  printf '  [debug] running:   %s\n' "${running_system:-unavailable}"
  printf '  [debug] next boot: %s\n' "${boot_system:-unavailable}"
fi

eval_manifest() {
  local mode="$1"
  local output="$2"
  local error_file="$3"
  local -a lock_args=()

  if [[ "$mode" == "candidate" ]]; then
    lock_args=(--reference-lock-file "$candidate_lock")
  fi

  if nix eval "${lock_args[@]}" --json "$manifest" > "$output" 2> "$error_file"; then
    return 0
  fi

  echo "ERROR: could not evaluate the $mode NixOS package manifest" >&2
  sed 's/^/  /' "$error_file" >&2
  return 1
}

current_manifest="$tmpdir/current-manifest.json"

if [[ "$inspect_packages" == true ]]; then
  if [[ "$debug" == true ]]; then
    echo "  [debug] evaluating current package manifest (evaluation 1 of 2)"
  fi
  eval_manifest current "$current_manifest" "$tmpdir/current-manifest.stderr" || exit 1
  declared_deriver=$(jq -r '.toplevelDeriver // empty' "$current_manifest")
else
  if [[ "$debug" == true ]]; then
    echo "  [debug] evaluating current toplevel derivation"
  fi
  if ! declared_deriver=$(nix eval --raw "${installable}.drvPath" 2> "$tmpdir/toplevel.stderr"); then
    sed 's/^/  /' "$tmpdir/toplevel.stderr" >&2
    exit 1
  fi
fi
running_deriver=$(get_deriver running "$running_system" || true)
boot_deriver=$(get_deriver next-boot "$boot_system" || true)
configuration_state="unavailable"
next_boot_state="unavailable"

if [[ -n "$declared_deriver" && -n "$running_deriver" ]]; then
  if [[ "$declared_deriver" == "$running_deriver" ]]; then
    configuration_state="applied"
    echo "  configuration:  applied"
  else
    configuration_state="differs"
    echo "  configuration:  differs from running system"
  fi
fi

if [[ -n "$declared_deriver" && -n "$boot_deriver" ]]; then
  if [[ "$declared_deriver" == "$boot_deriver" ]]; then
    next_boot_state="matches"
  else
    next_boot_state="differs"
    echo "  next boot:      differs from working configuration"
  fi
fi

if [[ "$debug" == true ]]; then
  printf '  [debug] declared:  %s\n' "${declared_deriver:-unavailable}"
  printf '  [debug] running:   %s\n' "${running_deriver:-unavailable}"
  printf '  [debug] next boot: %s\n' "${boot_deriver:-unavailable}"
  for diagnostics in "$tmpdir/current-manifest.stderr" "$tmpdir/toplevel.stderr"; do
    if [[ -s "$diagnostics" ]]; then
      sed 's/^/  [debug] /' "$diagnostics"
    fi
  done
fi

if [[ "$debug" == true ]]; then
  echo
  echo "[debug] Resolving updated inputs into: $candidate_lock"
fi
if ! nix flake update --flake . --output-lock-file "$candidate_lock" \
  > "$tmpdir/flake-update.stdout" 2> "$tmpdir/flake-update.stderr"; then
  sed 's/^/  /' "$tmpdir/flake-update.stderr" >&2
  exit 1
fi

after_lock_hash=$(sha256sum "$repo/flake.lock" | cut -d ' ' -f 1)
[[ "$before_lock_hash" == "$after_lock_hash" ]] || die "flake.lock changed unexpectedly"

jq -S . "$repo/flake.lock" > "$tmpdir/current-lock.normalized.json"
jq -S . "$candidate_lock" > "$tmpdir/candidate-lock.normalized.json"

echo
echo "Inputs"
input_changes_file="$tmpdir/input-changes.json"
jq -n \
  --slurpfile current "$repo/flake.lock" \
  --slurpfile candidate "$candidate_lock" '
    def identity:
      [(.locked.rev // null), (.locked.narHash // null), (.locked.url // null)]
      | map(select(. != null))
      | join(":");
    def details:
      {
        revision: (.locked.rev // null),
        narHash: (.locked.narHash // null),
        url: (.locked.url // null),
        lastModified: (.locked.lastModified // null),
        display: (
          (.locked.rev // .locked.narHash // .locked.url // "missing")
          | if length > 12 then .[0:8] else . end
        )
      };
    ($current[0].nodes // {}) as $old
    | ($candidate[0].nodes // {}) as $new
    | [
        ((($old | keys) + ($new | keys)) | unique | sort)[] as $name
        | ($old[$name] // null) as $before
        | ($new[$name] // null) as $after
        | select(($before | identity) != ($after | identity))
        | {
            name: $name,
            before: ($before | details),
            after: ($after | details)
          }
      ]
  ' > "$input_changes_file"

if [[ "$(jq 'length' "$input_changes_file")" -eq 0 ]]; then
  echo "  up to date"
else
  while IFS=$'\t' read -r name before after; do
    printf '  %-24s %s -> %s\n' "$name" "$before" "$after"
  done < <(jq -r '.[] | [.name, .before.display, .after.display] | @tsv' "$input_changes_file")
fi

if [[ "$debug" == true ]]; then
  if [[ -s "$tmpdir/flake-update.stdout" ]]; then
    sed 's/^/[debug] /' "$tmpdir/flake-update.stdout"
  fi
  if [[ -s "$tmpdir/flake-update.stderr" ]]; then
    sed 's/^/[debug] /' "$tmpdir/flake-update.stderr"
  fi

  echo
  echo "[debug] Current versus candidate lock diff:"
  if diff -u \
    --label current-flake.lock \
    --label candidate-flake.lock \
    "$tmpdir/current-lock.normalized.json" \
    "$tmpdir/candidate-lock.normalized.json"; then
    echo "  no input changes"
  fi
fi

print_package_list() {
  local label="$1"
  local file="$2"
  local selector="$3"
  local user_name="${4:-}"

  echo
  echo "$label"
  jq -r --arg user_name "$user_name" "
    $selector
    | sort_by([(.pname // \"\"), .name])[]
    | [(.pname // .name), (.version // \"unknown\"), .name, .path]
    | @tsv
  " "$file" | while IFS=$'\t' read -r pname version name out_path; do
    printf '  %-32s %-18s %s (%s)\n' "$pname" "$version" "$name" "$out_path"
  done
}

compare_manifest_section() {
  local label="$1"
  local current_file="$2"
  local candidate_file="$3"
  local selector="$4"
  local current_sorted="$tmpdir/${label}.current.sorted.json"
  local candidate_sorted="$tmpdir/${label}.candidate.sorted.json"

  jq -S "$selector" "$current_file" > "$current_sorted"
  jq -S "$selector" "$candidate_file" > "$candidate_sorted"

  echo
  echo "$label current versus candidate diff:"
  if diff -u \
    --label "${label}.current" \
    --label "${label}.candidate" \
    "$current_sorted" \
    "$candidate_sorted"; then
    echo "  no visible package changes"
  else
    echo "  visible package changes are shown above"
  fi
}

package_changes_file="$tmpdir/package-changes.json"
jq -n '[ ]' > "$package_changes_file"

if [[ "$inspect_packages" == true ]]; then
  candidate_manifest="$tmpdir/candidate-manifest.json"

  if [[ "$debug" == true ]]; then
    echo "  [debug] evaluating candidate package manifest (evaluation 2 of 2)"
  fi
  eval_manifest candidate "$candidate_manifest" "$tmpdir/candidate-manifest.stderr" || exit 1

  echo
  echo "Packages"

  current_packages="$tmpdir/current-packages.json"
  candidate_packages="$tmpdir/candidate-packages.json"

  for manifest_and_output in \
    "$current_manifest|$current_packages" \
    "$candidate_manifest|$candidate_packages"; do
    manifest="${manifest_and_output%%|*}"
    output="${manifest_and_output#*|}"
    jq -S '
      reduce ([
        (.activeOptionPackages[]?),
        (.userPackages | to_entries[]? | .value[]?),
        (.systemPackages[]?),
        (.manual | to_entries[]? | .value | select(. != null))
      ][]) as $package (
        {};
        .[($package.pname // $package.name)] = $package
      )
      | [.[]]
      | sort_by(.pname // .name)
    ' "$manifest" > "$output"
  done

  jq -n \
    --slurpfile current "$current_packages" \
    --slurpfile candidate "$candidate_packages" '
      def key: .pname // .name;
      def storeHash:
        try (.path | capture("^/nix/store/(?<hash>[^-]+)-").hash[0:8])
        catch "unknown";
      def details:
        if . == null then
          null
        else
          {
            name,
            pname,
            version: (.version // "unknown"),
            path,
            storeHash: storeHash
          }
        end;
      def keyed($items):
        reduce $items[] as $package ({}; .[($package | key)] = $package);

      keyed($current[0]) as $old
      | keyed($candidate[0]) as $new
      | [
          ((($old | keys) + ($new | keys)) | unique | sort)[] as $key
          | ($old[$key] // null) as $before
          | ($new[$key] // null) as $after
          | select(($before.path // null) != ($after.path // null))
          | {
              name: $key,
              kind: (
                if $before == null then "added"
                elif $after == null then "removed"
                elif ($before.version // "unknown") != ($after.version // "unknown") then "version"
                else "store"
                end
              ),
              before: ($before | details),
              after: ($after | details)
            }
        ]
    ' > "$package_changes_file"

  package_change_count=$(jq 'length' "$package_changes_file")
  if ((package_change_count == 0)); then
    echo "  up to date"
  else
    store_changes=$(jq '[.[] | select(.kind == "store")] | length' "$package_changes_file")
    reportable_changes=$((package_change_count - store_changes))
    while IFS=$'\t' read -r name change before_version after_version _old_hash _new_hash; do
      case "$change" in
        version)
          printf '  %-32s %s -> %s\n' "$name" "$before_version" "$after_version"
          ;;
        added)
          printf '  %-32s added (%s)\n' "$name" "$after_version"
          ;;
        removed)
          printf '  %-32s removed (%s)\n' "$name" "$before_version"
          ;;
      esac
    done < <(jq -r '
      .[]
      | [
          .name,
          .kind,
          (.before.version // ""),
          (.after.version // ""),
          (.before.storeHash // ""),
          (.after.storeHash // "")
        ]
      | @tsv
    ' "$package_changes_file")

    if ((reportable_changes == 0)); then
      echo "  no version updates"
    fi
    if ((store_changes > 0)); then
      printf '  same-version store changes: %d (use --debug for hashes)\n' "$store_changes"
    fi
  fi

  if [[ "$debug" == true ]]; then
    if [[ -s "$tmpdir/candidate-manifest.stderr" ]]; then
      sed 's/^/[debug] /' "$tmpdir/candidate-manifest.stderr"
    fi

    if [[ "${store_changes:-0}" -gt 0 ]]; then
      echo
      echo "[debug] Same-version store changes"
      jq -r '
        .[]
        | select(.kind == "store")
        | [.name, .after.version, .before.storeHash, .after.storeHash]
        | @tsv
      ' "$package_changes_file" | while IFS=$'\t' read -r name version old_hash new_hash; do
        printf '  %-32s %s (store %s -> %s)\n' "$name" "$version" "$old_hash" "$new_hash"
      done
    fi

    while IFS= read -r username; do
      print_package_list "[debug] user-packages (current lock; user: $username)" "$current_manifest" ".userPackages[\$user_name]" "$username"
    done < <(jq -r '.userPackages | keys[]' "$current_manifest")

    while IFS= read -r username; do
      print_package_list "[debug] user-packages (candidate lock; user: $username)" "$candidate_manifest" ".userPackages[\$user_name]" "$username"
    done < <(jq -r '.userPackages | keys[]' "$candidate_manifest")

    compare_manifest_section user-packages "$current_manifest" "$candidate_manifest" '.userPackages'

    print_package_list "[debug] system-packages (current lock)" "$current_manifest" '.systemPackages'
    print_package_list "[debug] system-packages (candidate lock)" "$candidate_manifest" '.systemPackages'
    compare_manifest_section system-packages "$current_manifest" "$candidate_manifest" '.systemPackages'

    print_package_list "[debug] active package options (current lock)" "$current_manifest" '.activeOptionPackages'
    print_package_list "[debug] active package options (candidate lock)" "$candidate_manifest" '.activeOptionPackages'
    compare_manifest_section active-package-options "$current_manifest" "$candidate_manifest" '.activeOptionPackages'

    echo
    echo "[debug] Manual package-valued options"
    echo "These are intentionally explicit because NixOS has no universal package-option registry."

    # Keep this list small and evidence-based. Add an option here when a package is
    # selected by a module rather than appearing in one of the package lists above.
    MANUAL_OPTIONS=(
      "systemd|systemd.package"
      "kernel|boot.kernelPackages.kernel"
      "nvidia|hardware.nvidia.package"
      "qemu|virtualisation.libvirtd.qemu.package"
      "kvmfr|boot.kernelPackages.kvmfr"
    )

    for option in "${MANUAL_OPTIONS[@]}"; do
      label="${option%%|*}"
      option_path="${option#*|}"
      current_file="$tmpdir/manual-${label}.current.json"
      candidate_file="$tmpdir/manual-${label}.candidate.json"

      jq -S --arg label "$label" '.manual[$label]' "$current_manifest" > "$current_file"
      jq -S --arg label "$label" '.manual[$label]' "$candidate_manifest" > "$candidate_file"

      echo
      echo "$label: ${configuration}.config.${option_path}"
      if [[ "$(jq -r 'if . == null then "null" else "value" end' "$current_file")" == "null" && \
            "$(jq -r 'if . == null then "null" else "value" end' "$candidate_file")" == "null" ]]; then
        echo "  unavailable in both configurations"
        continue
      fi

      echo "  current:"
      jq . "$current_file"
      echo "  candidate:"
      jq . "$candidate_file"
      echo "  diff:"
      if ! diff -u \
        --label "${label}.current" \
        --label "${label}.candidate" \
        "$current_file" \
        "$candidate_file"; then
        true
      fi
    done
  fi
else
  echo
  echo "Packages"
  echo "  skipped (--source-only)"
fi

if [[ "$build_closure" == true ]]; then
  echo
  echo "Building candidate system closure (explicitly requested with --build)..."
  if [[ "${NIXOS_UPDATE_CHECKER_IN_SCOPE:-}" == "1" ]]; then
    echo "WARNING: resource limits do not apply to Nix daemon build workers; omit --build for a fully low-impact check." >&2
  fi

  baseline_system="$running_system"
  baseline_label="running system"
  if [[ -n "$boot_system" && "$boot_system" != "$running_system" ]]; then
    baseline_system="$boot_system"
    baseline_label="next-boot system"
  fi

  [[ -n "$baseline_system" ]] || die "no running or next-boot system closure is available"

  candidate_system=$(nix build \
    --no-link \
    --print-out-paths \
    --no-write-lock-file \
    --reference-lock-file "$candidate_lock" \
    "$installable")

  echo "  baseline: $baseline_label ($baseline_system)"
  echo "  candidate: $candidate_system"
  echo
  echo "Complete closure diff:"
  nix store diff-closures "$baseline_system" "$candidate_system"
fi

echo
echo "flake.lock unchanged"

if [[ "$output_format" == "json" ]]; then
  resources_limited_json=false
  if [[ "${NIXOS_UPDATE_CHECKER_IN_SCOPE:-}" == "1" ]]; then
    resources_limited_json=true
  fi

  if [[ "$debug" == true && -s "$human_output" ]]; then
    sed 's/^/[debug-cli] /' "$human_output" >&2
  fi

  generated_at=$(date --iso-8601=seconds)
  jq -n \
    --arg generatedAt "$generated_at" \
    --arg backendVersion "$backend_version" \
    --argjson schemaVersion "$schema_version" \
    --arg host "$host" \
    --arg repository "$repo" \
    --arg runningPath "${running_system:-}" \
    --arg nextBootPath "${boot_system:-}" \
    --arg runningGeneration "$running_generation" \
    --arg nextBootGeneration "$boot_generation" \
    --arg declaredDeriver "${declared_deriver:-}" \
    --arg runningDeriver "${running_deriver:-}" \
    --arg nextBootDeriver "${boot_deriver:-}" \
    --arg configurationState "$configuration_state" \
    --arg nextBootState "$next_boot_state" \
    --arg cpuQuota "$cpu_quota" \
    --argjson resourcesLimited "$resources_limited_json" \
    --argjson rebootPending "$reboot_pending_json" \
    --argjson packagesInspected "$inspect_packages" \
    --slurpfile inputs "$input_changes_file" \
    --slurpfile packageChanges "$package_changes_file" '
      def nullable: if . == "" then null else . end;
      ($inputs[0]) as $inputChanges
      | ($packageChanges[0]) as $packages
      | {
          schemaVersion: $schemaVersion,
          backendVersion: $backendVersion,
          generatedAt: $generatedAt,
          status: "success",
          host: $host,
          repository: $repository,
          resourcePolicy: {
            limited: $resourcesLimited,
            cpuQuota: (if $resourcesLimited then $cpuQuota else null end),
            nice: (if $resourcesLimited then 19 else null end),
            ioClass: (if $resourcesLimited then "idle" else null end)
          },
          system: {
            runningPath: ($runningPath | nullable),
            nextBootPath: ($nextBootPath | nullable),
            runningGeneration: ($runningGeneration | nullable),
            nextBootGeneration: ($nextBootGeneration | nullable),
            rebootPending: $rebootPending,
            configurationState: $configurationState,
            nextBootState: $nextBootState,
            declaredDeriver: ($declaredDeriver | nullable),
            runningDeriver: ($runningDeriver | nullable),
            nextBootDeriver: ($nextBootDeriver | nullable)
          },
          inputs: $inputChanges,
          packages: {
            inspected: $packagesInspected,
            changes: $packages,
            summary: {
              total: ($packages | length),
              versions: ([$packages[] | select(.kind == "version")] | length),
              additions: ([$packages[] | select(.kind == "added")] | length),
              removals: ([$packages[] | select(.kind == "removed")] | length),
              storeOnly: ([$packages[] | select(.kind == "store")] | length)
            }
          },
          updatesAvailable: (($inputChanges | length) > 0 or ($packages | length) > 0),
          lockFile: {
            path: ($repository + "/flake.lock"),
            modified: false
          }
        }
    ' >&3
fi
