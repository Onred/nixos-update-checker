#!/usr/bin/env bash

set -euo pipefail

report_path=""
repository=""
temporary_directory=""
candidate_lock_pid=""
baseline_query_pid=""
candidate_query_pid=""
worker_pool_pid=""
worker_count_used=0
worker_derivation_count=0
state_path=${NIXOS_UPDATE_CHECKER_STATE:-/var/lib/nixos-update-checker/system-lock.json}
running_link=${NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM:-/run/current-system}
boot_link=${NIXOS_UPDATE_CHECKER_BOOT_SYSTEM:-/nix/var/nix/profiles/system}
profile_directory=${NIXOS_UPDATE_CHECKER_PROFILE_DIRECTORY:-/nix/var/nix/profiles}
lock_timeout=${NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT:-30}
store=${NIXOS_UPDATE_CHECKER_STORE:-local}

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-service [--report PATH] REPOSITORY

Build an updated candidate for a flake-based NixOS configuration and publish a
JSON report. The working flake.lock is never modified.
EOF
}

cleanup() {
  local pid
  for pid in "$candidate_lock_pid" "$baseline_query_pid" "$candidate_query_pid" \
    "$worker_pool_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$candidate_lock_pid" "$baseline_query_pid" "$candidate_query_pid" \
    "$worker_pool_pid"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}

stop_checker() {
  trap - TERM INT
  exit 143
}

trap cleanup EXIT
trap stop_checker TERM INT

write_json_file() {
  local source=$1
  local destination=$2
  mkdir -p "$(dirname "$destination")"
  local temporary_file
  temporary_file=$(mktemp "$(dirname "$destination")/.${destination##*/}.XXXXXX")
  install -m 0644 "$source" "$temporary_file"
  mv -f "$temporary_file" "$destination"
}

write_report() {
  local source=$1
  if [[ -z "$report_path" ]]; then
    cat "$source"
  else
    write_json_file "$source" "$report_path"
  fi
}

log() {
  printf 'INFO: %s\n' "$*" >&2
}

fail() {
  local message=$1
  local diagnostics=${2:-}
  printf 'ERROR: %s\n' "$message" >&2
  if [[ -n "$diagnostics" ]]; then
    printf '%s\n' "$diagnostics" >&2
  fi

  if [[ -n "$report_path" && -n "$temporary_directory" ]]; then
    local error_report="$temporary_directory/error.json"
    jq -n \
      --arg generatedAt "$(date --iso-8601=seconds)" \
      --arg repository "$repository" \
      --arg message "$message" \
      --arg diagnostics "$diagnostics" \
      '{
        schemaVersion: 2,
        generatedAt: $generatedAt,
        status: "error",
        repository: $repository,
        error: {message: $message, diagnostics: $diagnostics}
      }' >"$error_report"
    write_report "$error_report"
  fi
  exit 1
}

resolved_path() {
  readlink -f "$1" 2>/dev/null || true
}

generation_number() {
  local system=$1
  local link target name number highest=""
  for link in "$profile_directory"/system-*-link; do
    [[ -e "$link" ]] || continue
    target=$(resolved_path "$link")
    if [[ "$target" == "$system" ]]; then
      name=${link##*/system-}
      number=${name%-link}
      if [[ "$number" =~ ^[0-9]+$ ]] && \
        { [[ -z "$highest" ]] || ((10#$number > 10#$highest)); }; then
        highest=$number
      fi
    fi
  done
  [[ -z "$highest" ]] || printf '%s\n' "$highest"
}

logical_cpu_count() {
  local cpu_list=${NIXOS_UPDATE_CHECKER_CPU_LIST:-}
  local key value
  if [[ -z "$cpu_list" ]]; then
    while read -r key value _; do
      if [[ "$key" == "Cpus_allowed_list:" ]]; then
        cpu_list=$value
        break
      fi
    done </proc/self/status
  fi

  local total=0 item first last
  local -a ranges
  IFS=',' read -ra ranges <<<"$cpu_list"
  for item in "${ranges[@]}"; do
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      first=${BASH_REMATCH[1]}
      last=${BASH_REMATCH[2]}
      ((total += 10#$last - 10#$first + 1))
    elif [[ "$item" =~ ^[0-9]+$ ]]; then
      ((total += 1))
    fi
  done

  if ((total > 0)); then
    printf '%s\n' "$total"
  else
    nproc
  fi
}

deriver_for() {
  local system=$1
  nix --store "$store" path-info --derivation "$system" 2>/dev/null | head -n 1 || true
}

realise_with_workers() {
  local deriver=$1
  local worker_limit=$2
  local graph="$temporary_directory/candidate-derivations.json"
  local graph_log="$temporary_directory/candidate-derivations.log"
  local derivations="$temporary_directory/candidate-derivations.txt"
  local requisites="$temporary_directory/candidate-requisites.txt"
  local requisites_log="$temporary_directory/candidate-requisites.log"
  local queue="$temporary_directory/worker-queue.txt"
  local remaining="$temporary_directory/worker-remaining.txt"
  local ready="$temporary_directory/worker-ready.txt"
  local blocked="$temporary_directory/worker-blocked.txt"
  local worker_log="$temporary_directory/workers.log"
  local worker_roots="$temporary_directory/worker-roots"

  log "Finding uncached candidate derivations."
  if ! nix --store "$store" derivation show --recursive "$deriver" \
    >"$graph" 2>"$graph_log"; then
    fail "Could not inspect the candidate derivation graph." "$(<"$graph_log")"
  fi

  jq -r '
    def storePath:
      if startswith("/") then . else "/nix/store/" + . end;
    if has("derivations") then
      .derivations | to_entries[] |
      [(.key | storePath),
       ([((.value.inputs.drvs // {}) | keys[]) | storePath] | join(" ")),
       ([.value.outputs[]?.path? | select(type == "string") | storePath] | join(" "))]
    else
      to_entries[] | select(.key | endswith(".drv")) |
      [(.key | storePath),
       ([((.value.inputDrvs // {}) | keys[]) | storePath] | join(" ")),
       ([.value.outputs[]?.path? | select(type == "string") | storePath] | join(" "))]
    end | join("\u001f")
  ' "$graph" >"$derivations"

  declare -A missing=()
  declare -A dependencies=()
  local separator=$'\x1f'
  local drv dependency_paths output_paths output dependency
  local output_missing
  while IFS="$separator" read -r drv dependency_paths output_paths; do
    dependencies["$drv"]=$dependency_paths
    output_missing=false
    if [[ -z "$output_paths" ]]; then
      output_missing=true
    else
      for output in $output_paths; do
        if [[ ! -e "$output" ]]; then
          output_missing=true
          break
        fi
      done
    fi
    if [[ "$output_missing" == true ]]; then
      missing["$drv"]=1
    fi
  done <"$derivations"

  if ! nix-store --store "$store" --query --requisites "$deriver" \
    >"$requisites" 2>"$requisites_log"; then
    fail "Could not order the candidate derivations." "$(<"$requisites_log")"
  fi

  : >"$queue"
  while IFS= read -r drv; do
    if [[ "$drv" == *.drv && -n "${missing[$drv]:-}" ]]; then
      printf '%s\n' "$drv" >>"$queue"
    fi
  done <"$requisites"

  worker_derivation_count=$(wc -l <"$queue")
  if ((worker_derivation_count == 0)); then
    log "Every candidate derivation is already available in the store."
    return
  fi

  log "Realising $worker_derivation_count uncached derivations with up to $worker_limit independent workers."
  install -m 0644 "$queue" "$remaining"
  : >"$worker_log"
  mkdir -p "$worker_roots"

  local wave=0 ready_count wave_workers worker_status
  while [[ -s "$remaining" ]]; do
    : >"$ready"
    : >"$blocked"
    while IFS= read -r drv; do
      output_missing=false
      for dependency in ${dependencies[$drv]:-}; do
        if [[ -n "${missing[$dependency]:-}" ]]; then
          output_missing=true
          break
        fi
      done
      if [[ "$output_missing" == true ]]; then
        printf '%s\n' "$drv" >>"$blocked"
      else
        printf '%s\n' "$drv" >>"$ready"
      fi
    done <"$remaining"

    ready_count=$(wc -l <"$ready")
    if ((ready_count == 0)); then
      fail "Could not find a buildable candidate derivation." \
        "The remaining derivation graph contains a dependency cycle or an unresolved output."
    fi

    wave_workers=$worker_limit
    if ((wave_workers > ready_count)); then
      wave_workers=$ready_count
    fi
    if ((wave_workers > worker_count_used)); then
      worker_count_used=$wave_workers
    fi
    ((wave += 1))
    log "Starting worker wave $wave with $ready_count derivations and $wave_workers workers."

    # The variables in this string intentionally expand in each worker shell.
    # shellcheck disable=SC2016
    xargs -r -P "$wave_workers" -I '{}' \
      "$BASH" -c '
        drv=$1
        roots=$2
        store=$3
        nix-store --store "$store" --realise \
          --option max-jobs 1 --option cores 1 --option max-substitution-jobs 1 \
          --add-root "$roots/${drv##*/}" "$drv"
      ' nixos-update-checker-worker '{}' "$worker_roots" "$store" \
      <"$ready" > >(tee -a "$worker_log" >&2) 2>&1 &
    worker_pool_pid=$!
    worker_status=0
    wait "$worker_pool_pid" || worker_status=$?
    worker_pool_pid=""
    if ((worker_status != 0)); then
      fail "One or more candidate build workers failed." "$(<"$worker_log")"
    fi

    while IFS= read -r drv; do
      unset "missing[$drv]"
    done <"$ready"
    install -m 0644 "$blocked" "$remaining"
  done
}

query_path_info() {
  local system=$1
  local destination=$2
  local diagnostics=$3
  local command_pid=""
  trap 'if [[ -n "$command_pid" ]]; then kill "$command_pid" 2>/dev/null || true; fi' TERM INT

  nix --store "$store" path-info --json --json-format 1 --recursive --size \
    "$system" >"$destination" 2>"$diagnostics" &
  command_pid=$!
  if wait "$command_pid"; then
    command_pid=""
    trap - TERM INT
    return
  fi
  command_pid=""

  nix --store "$store" path-info --json --recursive --size \
    "$system" >"$destination" 2>"$diagnostics" &
  command_pid=$!
  local status=0
  wait "$command_pid" || status=$?
  command_pid=""
  trap - TERM INT
  return "$status"
}

while (($#)); do
  case "$1" in
    --report)
      (($# >= 2)) || { usage >&2; exit 2; }
      report_path=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "nixos-update-checker-service 3.1.7"
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$repository" ]] || { usage >&2; exit 2; }
      repository=$1
      shift
      ;;
  esac
done

[[ -n "$repository" ]] || { usage >&2; exit 2; }
repository=$(readlink -f "$repository")
temporary_directory=$(mktemp -d -t nixos-update-checker.XXXXXX)

if [[ -n "${NIXOS_UPDATE_CHECKER_LOCK:-}" ]]; then
  exec 9>"$NIXOS_UPDATE_CHECKER_LOCK"
  if ! flock -w "$lock_timeout" 9; then
    printf 'ERROR: Another update operation still holds the shared lock.\n' >&2
    exit 75
  fi
fi

log "Inspecting the running and default-boot generations."
[[ -f "$repository/flake.nix" ]] || fail "No flake.nix exists in $repository."
[[ -f "$repository/flake.lock" ]] || fail "This checker requires a flake.lock baseline."

running_system=$(resolved_path "$running_link")
boot_system=$(resolved_path "$boot_link")
[[ -n "$running_system" ]] || fail "No running NixOS system is available."
if [[ -z "$boot_system" ]]; then
  boot_system=$running_system
fi

baseline_kind="running"
baseline_system=$running_system
ready_for_boot=false
if [[ "$boot_system" != "$running_system" ]]; then
  baseline_kind="boot"
  baseline_system=$boot_system
  ready_for_boot=true
fi

running_generation=$(generation_number "$running_system")
boot_generation=$(generation_number "$boot_system")
flake="path:$repository"
hostname=${NIXOS_UPDATE_CHECKER_HOSTNAME:-$(cat /proc/sys/kernel/hostname)}
lock_hash=$(sha256sum "$repository/flake.lock" | cut -d ' ' -f 1)
started=$(date +%s)
candidate_lock="$temporary_directory/candidate.lock"

# Lock resolution is independent of selecting and evaluating the current
# configuration. Run both within the same service-wide CPU quota.
log "Resolving updated configuration inputs."
nix --store "$store" flake update --flake "$flake" \
  --output-lock-file "$candidate_lock" \
  2> >(tee "$temporary_directory/update.log" >&2) &
candidate_lock_pid=$!

# This is a Nix expression; ${name} must reach Nix literally.
# shellcheck disable=SC2016
discovery_expression='configs: map (name: let value = builtins.tryEval configs.${name}.config.networking.hostName; in { inherit name; hostName = if value.success then value.value else ""; }) (builtins.attrNames configs)'
log "Evaluating the current NixOS configuration."
if ! configurations=$(nix --store "$store" eval --json --no-write-lock-file \
  --apply "$discovery_expression" "$flake#nixosConfigurations" 2>"$temporary_directory/discovery.log"); then
  fail "Could not enumerate NixOS configurations." "$(<"$temporary_directory/discovery.log")"
fi

configuration=$(jq -r --arg hostname "$hostname" '
  if length == 1 then .[0].name
  else ([.[] | select(.hostName == $hostname)] | if length == 1 then .[0].name else empty end)
  end
' <<<"$configurations")
[[ -n "$configuration" ]] || fail \
  "Could not select one NixOS configuration for host $hostname." \
  "Available configurations: $(jq -c '.' <<<"$configurations")"

installable="$flake#nixosConfigurations.\"$configuration\".config.system.build.toplevel"
if ! declared_deriver=$(nix --store "$store" eval --raw --no-write-lock-file \
  "$installable.drvPath" 2>"$temporary_directory/declared.log"); then
  fail "Could not evaluate the configured NixOS system." "$(<"$temporary_directory/declared.log")"
fi
baseline_deriver=$(deriver_for "$baseline_system")

baseline_lock="$temporary_directory/baseline.lock"
input_baseline_source="runningNixpkgsFallback"
input_baseline_complete=false
record_system_lock=false

if [[ -n "$baseline_deriver" && "$declared_deriver" == "$baseline_deriver" ]]; then
  install -m 0644 "$repository/flake.lock" "$baseline_lock"
  input_baseline_source="workingConfiguration"
  input_baseline_complete=true
  record_system_lock=true
elif [[ -f "$state_path" ]] && jq -e \
  --arg repository "$repository" --arg system "$baseline_system" '
    .schemaVersion == 1 and .repository == $repository and .system == $system and (.lock | type == "object")
  ' "$state_path" >/dev/null 2>&1; then
  jq '.lock' "$state_path" >"$baseline_lock"
  input_baseline_source="savedSystemLock"
  input_baseline_complete=true
else
  install -m 0644 "$repository/flake.lock" "$baseline_lock"
fi

baseline_revision=${NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION:-}
if [[ -z "$baseline_revision" && -x "$baseline_system/sw/bin/nixos-version" ]]; then
  baseline_revision=$("$baseline_system/sw/bin/nixos-version" --json 2>/dev/null | \
    jq -r '.nixpkgsRevision // empty' || true)
fi

if wait "$candidate_lock_pid"; then
  candidate_lock_pid=""
else
  candidate_lock_pid=""
  fail "Could not resolve updated configuration inputs." "$(<"$temporary_directory/update.log")"
fi

[[ "$lock_hash" == "$(sha256sum "$repository/flake.lock" | cut -d ' ' -f 1)" ]] || \
  fail "flake.lock changed while the check was running."

jq -n \
  --slurpfile baselineLock "$baseline_lock" \
  --slurpfile candidateLock "$candidate_lock" \
  --arg fallbackRevision "$baseline_revision" \
  --argjson complete "$input_baseline_complete" '
  def followPath($lock; $current; $path):
    if ($path | length) == 0 then $current
    else
      ($current.inputs[$path[0]] // null) as $reference |
      if ($reference | type) == "string" then
        followPath($lock; ($lock.nodes[$reference] // {}); $path[1:])
      elif ($reference | type) == "array" then
        followPath($lock; ($lock.nodes[$lock.root] // {}); $reference) as $followed |
        followPath($lock; $followed; $path[1:])
      else {} end
    end;
  def node($lock; $name):
    ($lock.nodes[$lock.root].inputs[$name] // null) as $reference |
    if ($reference | type) == "string" then ($lock.nodes[$reference] // {})
    elif ($reference | type) == "array" then
      followPath($lock; ($lock.nodes[$lock.root] // {}); $reference)
    else {} end;
  def detail($lock; $name):
    (node($lock; $name).locked // {}) as $value |
    {
      revision: ($value.rev // null),
      narHash: ($value.narHash // null),
      url: ($value.url // null),
      lastModified: ($value.lastModified // null),
      display: (($value.rev // $value.lastModified // $value.narHash // $value.url // "missing") | tostring | .[0:12])
    };
  def identity($value):
    if $value.revision != null then "rev:" + $value.revision
    elif $value.narHash != null then "hash:" + $value.narHash
    elif $value.url != null then "url:" + $value.url
    elif $value.lastModified != null then "time:" + ($value.lastModified | tostring)
    else "missing" end;
  ($baselineLock[0]) as $baseline |
  ($candidateLock[0]) as $candidate |
  (($baseline.nodes[$baseline.root].inputs // {}) | keys) as $baselineNames |
  (($candidate.nodes[$candidate.root].inputs // {}) | keys) as $candidateNames |
  [($baselineNames + $candidateNames | unique)[] as $name |
    (detail($baseline; $name)) as $originalBefore |
    (if ($complete | not) and $name == "nixpkgs" and $fallbackRevision != ""
     then ($originalBefore + {revision: $fallbackRevision, narHash: null, display: $fallbackRevision[0:12]})
     else $originalBefore end) as $before |
    (detail($candidate; $name)) as $after |
    select(identity($before) != identity($after)) |
    {name: $name, before: $before, after: $after}
  ]
' >"$temporary_directory/inputs.json"

logical_cpus=$(logical_cpu_count)
worker_budget=$logical_cpus
if ((worker_budget > 32)); then
  worker_budget=32
fi

# Each independent Nix process builds one derivation with one declared core.
# This makes concurrency explicit instead of relying on one coordinator to
# happen to have several buildable derivations at the same time.
max_jobs=$worker_budget
cores_per_job=1
substitution_jobs=$max_jobs
if ((substitution_jobs > 4)); then
  substitution_jobs=4
fi

if ! candidate_deriver=$(nix --store "$store" eval --raw --no-write-lock-file \
  --reference-lock-file "$candidate_lock" \
  "$installable.drvPath" 2>"$temporary_directory/candidate-deriver.log"); then
  fail "Could not evaluate the candidate NixOS derivation." \
    "$(<"$temporary_directory/candidate-deriver.log")"
fi
realise_with_workers "$candidate_deriver" "$max_jobs"

log "Building the candidate with $max_jobs jobs and $cores_per_job cores per job."
if ! candidate_system=$(nix --store "$store" \
  --option max-substitution-jobs "$substitution_jobs" \
  build --no-link --print-out-paths --print-build-logs --no-write-lock-file \
  --reference-lock-file "$candidate_lock" \
  --max-jobs "$max_jobs" --cores "$cores_per_job" \
  "$installable" 2> >(tee "$temporary_directory/build.log" >&2)); then
  fail "Could not build the candidate NixOS system." "$(<"$temporary_directory/build.log")"
fi
candidate_system=$(head -n 1 <<<"$candidate_system")

baseline_json="$temporary_directory/baseline.json"
candidate_json="$temporary_directory/candidate.json"
baseline_log="$temporary_directory/baseline-path-info.log"
candidate_log="$temporary_directory/candidate-path-info.log"

log "Inspecting baseline and candidate closures."
if [[ "$baseline_system" == "$candidate_system" ]]; then
  if ! query_path_info "$baseline_system" "$baseline_json" "$baseline_log"; then
    fail "Could not inspect the realized closure $baseline_system." "$(<"$baseline_log")"
  fi
  install -m 0644 "$baseline_json" "$candidate_json"
else
  query_path_info "$baseline_system" "$baseline_json" "$baseline_log" &
  baseline_query_pid=$!
  query_path_info "$candidate_system" "$candidate_json" "$candidate_log" &
  candidate_query_pid=$!

  baseline_status=0
  candidate_status=0
  wait "$baseline_query_pid" || baseline_status=$?
  baseline_query_pid=""
  wait "$candidate_query_pid" || candidate_status=$?
  candidate_query_pid=""

  if ((baseline_status != 0 || candidate_status != 0)); then
    diagnostics=""
    if ((baseline_status != 0)); then
      diagnostics+="Baseline closure ($baseline_system):"$'\n'"$(<"$baseline_log")"
    fi
    if ((candidate_status != 0)); then
      if [[ -n "$diagnostics" ]]; then
        diagnostics+=$'\n'
      fi
      diagnostics+="Candidate closure ($candidate_system):"$'\n'"$(<"$candidate_log")"
    fi
    fail "Could not inspect the realized system closures." "$diagnostics"
  fi
fi

log "Comparing package and closure changes."
jq -n \
  --slurpfile baseline "$temporary_directory/baseline.json" \
  --slurpfile candidate "$temporary_directory/candidate.json" '
  def identity:
    split("/")[-1] | sub("^[^-]+-"; "") as $base |
    try ($base | capture("^(?<name>.*?)-(?<version>[0-9].*)$"))
    catch {name: $base, version: ""};
  def packages($closure):
    $closure | to_entries |
    map(.key as $path | ($path | identity) + {
      path: $path,
      narSize: (.value.narSize // 0)
    }) |
    sort_by(.name) | group_by(.name) |
    map({
      key: .[0].name,
      value: {
        versions: (map(if .version == "" then "unversioned" else .version end) | unique | sort),
        entries: (map({path, narSize}) | sort_by(.path)),
        narSize: (map(.narSize) | add)
      }
    }) | from_entries;
  def public($package):
    if $package == null then null else {
      versions: $package.versions,
      paths: ($package.entries | map(.path)),
      narSize: $package.narSize
    } end;
  packages($baseline[0]) as $before |
  packages($candidate[0]) as $after |
  [((($before | keys) + ($after | keys)) | unique)[] as $name |
    (($before[$name].entries // []) | map(.path)) as $beforePaths |
    (($after[$name].entries // []) | map(.path)) as $afterPaths |
    select($beforePaths != $afterPaths) |
    ([($after[$name].entries // [])[] |
      select(.path as $path | ($beforePaths | index($path) | not)) | .narSize] | add // 0) as $added |
    ([($before[$name].entries // [])[] |
      select(.path as $path | ($afterPaths | index($path) | not)) | .narSize] | add // 0) as $removed |
    {
      name: $name,
      kind: (if $before[$name] == null then "added"
             elif $after[$name] == null then "removed"
             elif $before[$name].versions != $after[$name].versions then "version"
             else "rebuild" end),
      before: public($before[$name]),
      after: public($after[$name]),
      addedBytes: $added,
      removedBytes: $removed,
      deltaBytes: ($added - $removed)
    }
  ]
' >"$temporary_directory/closure-changes.json"

if [[ "$record_system_lock" == true ]]; then
  jq -n \
    --arg repository "$repository" \
    --arg system "$baseline_system" \
    --arg recordedAt "$(date --iso-8601=seconds)" \
    --slurpfile lock "$repository/flake.lock" '
    {
      schemaVersion: 1,
      repository: $repository,
      system: $system,
      recordedAt: $recordedAt,
      lock: $lock[0]
    }
  ' >"$temporary_directory/system-lock.json"
  if ! write_json_file "$temporary_directory/system-lock.json" "$state_path"; then
    fail "Could not save system lock state at $state_path."
  fi
fi

elapsed=$(($(date +%s) - started))
generated_at=$(date --iso-8601=seconds)

jq -n \
  --arg generatedAt "$generated_at" \
  --arg repository "$repository" \
  --arg configuration "$configuration" \
  --arg runningSystem "$running_system" \
  --arg bootSystem "$boot_system" \
  --arg runningGeneration "$running_generation" \
  --arg bootGeneration "$boot_generation" \
  --arg baselineKind "$baseline_kind" \
  --arg baselineSystem "$baseline_system" \
  --arg candidateSystem "$candidate_system" \
  --arg inputBaselineSource "$input_baseline_source" \
  --argjson readyForBoot "$ready_for_boot" \
  --argjson inputBaselineComplete "$input_baseline_complete" \
  --argjson elapsed "$elapsed" \
  --argjson logicalCpus "$logical_cpus" \
  --argjson workerBudget "$worker_budget" \
  --argjson maxJobs "$max_jobs" \
  --argjson coresPerJob "$cores_per_job" \
  --argjson substitutionJobs "$substitution_jobs" \
  --argjson workerCount "$worker_count_used" \
  --argjson workerDerivations "$worker_derivation_count" \
  --slurpfile inputs "$temporary_directory/inputs.json" \
  --slurpfile changes "$temporary_directory/closure-changes.json" \
  --slurpfile baseline "$temporary_directory/baseline.json" \
  --slurpfile candidate "$temporary_directory/candidate.json" '
  def numberOrNull($value): if $value == "" then null else ($value | tonumber) end;
  ($changes[0] | map(select(.kind != "rebuild"))) as $packages |
  ($changes[0] | map(select(.kind == "rebuild"))) as $rebuildChanges |
  ($rebuildChanges | map(.addedBytes) | add // 0) as $rebuildAdded |
  ($rebuildChanges | map(.removedBytes) | add // 0) as $rebuildRemoved |
  ($baseline[0] | to_entries | map(.value.narSize // 0) | add // 0) as $baselineSize |
  ($candidate[0] | to_entries | map(.value.narSize // 0) | add // 0) as $candidateSize |
  {
    schemaVersion: 2,
    generatedAt: $generatedAt,
    status: "success",
    repository: $repository,
    configuration: $configuration,
    inputs: $inputs[0],
    inputBaseline: {
      source: $inputBaselineSource,
      complete: $inputBaselineComplete,
      system: $baselineSystem
    },
    packages: {
      changes: $packages,
      rebuilds: {
        count: ($rebuildChanges | length),
        addedBytes: $rebuildAdded,
        removedBytes: $rebuildRemoved,
        deltaBytes: ($rebuildAdded - $rebuildRemoved),
        items: ($rebuildChanges | map({
          name,
          versions: (.after.versions // .before.versions // [])
        }))
      }
    },
    system: {
      running: {path: $runningSystem, generation: numberOrNull($runningGeneration)},
      boot: {path: $bootSystem, generation: numberOrNull($bootGeneration)},
      baseline: $baselineKind,
      baselinePath: $baselineSystem,
      readyForBoot: $readyForBoot,
      candidate: $candidateSystem
    },
    build: {
      elapsedSeconds: $elapsed,
      logicalCpus: $logicalCpus,
      workerBudget: $workerBudget,
      maxJobs: $maxJobs,
      coresPerJob: $coresPerJob,
      substitutionJobs: $substitutionJobs,
      workerCount: $workerCount,
      workerDerivations: $workerDerivations,
      baselineClosureBytes: $baselineSize,
      candidateClosureBytes: $candidateSize,
      closureDeltaBytes: ($candidateSize - $baselineSize)
    },
    updatesAvailable: (($inputs[0] | length) + ($packages | length) + ($rebuildChanges | length) > 0)
  }
' >"$temporary_directory/report.json"

[[ "$lock_hash" == "$(sha256sum "$repository/flake.lock" | cut -d ' ' -f 1)" ]] || \
  fail "flake.lock changed while the candidate was built."

write_report "$temporary_directory/report.json"
log "Update report published in ${elapsed}s."
