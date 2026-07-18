#!/usr/bin/env bash

set -euo pipefail

mode=preview
report_path=""
candidate_lock_path=""
repository=""
temporary_directory=""
state_path=${NIXOS_UPDATE_CHECKER_STATE:-/var/lib/nixos-update-checker/system-lock.json}
running_link=${NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM:-/run/current-system}
boot_link=${NIXOS_UPDATE_CHECKER_BOOT_SYSTEM:-/nix/var/nix/profiles/system}
profile_directory=${NIXOS_UPDATE_CHECKER_PROFILE_DIRECTORY:-/nix/var/nix/profiles}
lock_timeout=${NIXOS_UPDATE_CHECKER_LOCK_TIMEOUT:-30}
store=${NIXOS_UPDATE_CHECKER_STORE:-local}
discovery_file=${NIXOS_UPDATE_CHECKER_DISCOVERY:-$(dirname "$0")/../nix/discovery.nix}

usage() {
  cat <<'EOF'
Usage: nixos-update-checker-service [--build] [--report PATH]
                                    [--candidate-lock PATH] REPOSITORY

Without --build, evaluate an updated NixOS candidate without realizing it and
publish a schema-3 preview report. --build realizes the exact saved candidate
and replaces the preview with a verified closure report.
EOF
}

cleanup() {
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

  # A failed manual build leaves the valid preview in place so it can be
  # retried. A failed preview replaces an older result with an honest error.
  if [[ "$mode" == preview && -n "$report_path" && -n "$temporary_directory" ]]; then
    jq -n \
      --arg generatedAt "$(date --iso-8601=seconds)" \
      --arg repository "$repository" \
      --arg message "$message" \
      --arg diagnostics "$diagnostics" '
      {
        schemaVersion: 3,
        generatedAt: $generatedAt,
        status: "error",
        analysis: {mode: "preview"},
        repository: $repository,
        error: {message: $message, diagnostics: $diagnostics}
      }
    ' >"$temporary_directory/error.json"
    write_report "$temporary_directory/error.json"
    if [[ -n "$candidate_lock_path" ]]; then
      rm -f "$candidate_lock_path"
    fi
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

sha256_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

deriver_for() {
  local system=$1
  nix --store "$store" path-info --derivation "$system" 2>/dev/null | head -n 1 || true
}

query_path_info() {
  local query_store=$1
  local destination=$2
  local diagnostics=$3
  shift 3

  if (($# == 0)); then
    printf '{}\n' >"$destination"
    return
  fi

  if nix --store "$query_store" path-info --json --json-format 1 \
    --recursive --size "$@" >"$destination" 2>"$diagnostics"; then
    return
  fi
  nix --store "$query_store" path-info --json --recursive --size \
    "$@" >"$destination" 2>"$diagnostics"
}

normalise_discovery() {
  local source=$1
  local destination=$2
  jq '
    .packages |= (
      sort_by(.storePath, .source, .label) |
      group_by(.storePath) |
      map({
        storePath: .[0].storePath,
        drvPath: .[0].drvPath,
        name: .[0].name,
        version: .[0].version,
        label: ([.[].label | select(. != "")] | first // .[0].name),
        position: ([.[].position | select(. != "")] | first // ""),
        sources: ([.[].source] | unique | sort)
      })
    )
  ' "$source" >"$destination"
}

query_candidate_metadata() {
  local roots_file=$1
  local destination=$2
  local directory="$temporary_directory/cache-parts"
  mkdir -p "$directory"
  mapfile -t roots <"$roots_file"

  local index=0 query_store part diagnostics
  part="$directory/$index.json"
  diagnostics="$directory/$index.log"
  if ! query_path_info "$store" "$part" "$diagnostics" "${roots[@]}"; then
    log "The local store could not describe every candidate package."
    printf '{}\n' >"$part"
  fi
  ((index += 1))

  local config_json="$temporary_directory/nix-config.json"
  if nix config show --json >"$config_json" 2>"$temporary_directory/nix-config.log"; then
    mapfile -t substituters < <(jq -r '
      (.substituters.value // .substituters // []) |
      if type == "array" then .[] elif type == "string" then split(" ")[] else empty end
    ' "$config_json")
  else
    substituters=("https://cache.nixos.org/")
  fi

  for query_store in "${substituters[@]}"; do
    [[ -n "$query_store" && "$query_store" != "$store" ]] || continue
    part="$directory/$index.json"
    diagnostics="$directory/$index.log"
    log "Querying package metadata from $query_store."
    if ! query_path_info "$query_store" "$part" "$diagnostics" "${roots[@]}"; then
      log "Metadata query failed for $query_store; continuing with other stores."
      printf '{}\n' >"$part"
    fi
    ((index += 1))
  done

  jq -s '
    reduce .[] as $map ({};
      reduce (($map // {}) | to_entries[]) as $entry (.;
        if $entry.value == null or has($entry.key) then .
        else .[$entry.key] = ($entry.value + {previewSource: "cached"}) end
      )
    )
  ' "$directory"/*.json >"$destination"
}

add_preview_fallbacks() {
  local baseline=$1
  local graph=$2
  local discovery=$3
  local metadata=$4
  local destination=$5

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile graph "$graph" \
    --slurpfile discovery "$discovery" \
    --slurpfile metadata "$metadata" '
    def storePath:
      if startswith("/") then . else "/nix/store/" + . end;
    def identity($path):
      ($path | split("/")[-1] | sub("^[^-]+-"; "")) as $base |
      try ($base | capture("^(?<name>.*?)-(?<version>[0-9].*)$"))
      catch {name: $base, version: ""};
    def graphEntries:
      ($graph[0] | if has("derivations") then .derivations else . end) |
      to_entries |
      map(. as $entry |
        ($entry.value.env // {}) as $env |
        [($entry.value.outputs // {}) | to_entries[]? |
          (.value.path // .value) as $path |
          select($path | type == "string") |
          ($path | storePath) as $storePath |
          (identity($storePath)) as $parsed |
          {
            path: $storePath,
            name: ($env.pname // $parsed.name),
            version: (($env.version // $parsed.version) | tostring)
          }
        ]) | add // [];
    ($metadata[0]) as $confirmed |
    ($baseline[0] | keys | map(identity(.).name) | unique) as $baselineNames |
    ($confirmed | keys | map(identity(.).name) | unique) as $confirmedNames |
    (graphEntries |
      map(. as $item | select(
        ($baselineNames | index($item.name)) != null and
        ($confirmedNames | index($item.name)) == null
      )) |
      unique_by(.path)
    ) as $inferred |
    reduce $inferred[] as $item ($confirmed;
      if has($item.path) then . else
        .[$item.path] = {
          narSize: null,
          references: [$item.path],
          previewSource: "inferred",
          inferredName: $item.name,
          inferredVersion: $item.version
        }
      end
    ) |
    reduce $discovery[0].packages[] as $package (.;
      if has($package.storePath) then . else
        .[$package.storePath] = {
          narSize: null,
          references: [$package.storePath],
          previewSource: "configured"
        }
      end
    )
  ' >"$destination"
}

compare_closures() {
  local baseline=$1
  local candidate=$2
  local discovery=$3
  local destination=$4

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile candidate "$candidate" \
    --slurpfile discovery "$discovery" '
    def parsedIdentity($path):
      ($path | split("/")[-1] | sub("^[^-]+-"; "")) as $base |
      try ($base | capture("^(?<name>.*?)-(?<version>[0-9].*)$"))
      catch {name: $base, version: ""};
    def rootMap:
      reduce $discovery[0].packages[] as $package ({};
        .[$package.storePath] = $package
      );
    rootMap as $roots |
    def identity($path; $value):
      if $roots[$path] != null then
        {name: $roots[$path].name, version: $roots[$path].version}
      elif $value.inferredName != null then
        {name: $value.inferredName, version: ($value.inferredVersion // "")}
      else parsedIdentity($path) end;
    def confidence($entries):
      if any($entries[]; .previewSource == "inferred") then "inferred"
      elif any($entries[]; .previewSource == "configured") then "configured"
      else "confirmed" end;
    def packages($closure):
      $closure | to_entries |
      map(.key as $path | (identity($path; .value)) + {
        path: $path,
        narSize: .value.narSize,
        previewSource: (.value.previewSource // "confirmed")
      }) |
      sort_by(.name) | group_by(.name) |
      map({
        key: .[0].name,
        value: {
          versions: (map(if .version == "" then "unversioned" else .version end) | unique | sort),
          entries: (map({path, narSize, previewSource}) | sort_by(.path)),
          narSize: ([.[].narSize | select(type == "number")] | add // 0),
          sizeKnown: all(.[]; .narSize | type == "number"),
          confidence: confidence(.)
        }
      }) | from_entries;
    def public($package):
      if $package == null then null else {
        versions: $package.versions,
        paths: ($package.entries | map(.path)),
        narSize: $package.narSize,
        sizeKnown: $package.sizeKnown,
        confidence: $package.confidence
      } end;
    packages($baseline[0]) as $before |
    packages($candidate[0]) as $after |
    [((($before | keys) + ($after | keys)) | unique)[] as $name |
      (($before[$name].entries // []) | map(.path)) as $beforePaths |
      (($after[$name].entries // []) | map(.path)) as $afterPaths |
      select($beforePaths != $afterPaths) |
      ([($after[$name].entries // [])[] |
        select(.path as $path | ($beforePaths | index($path) | not)) |
        .narSize | select(type == "number")] | add // 0) as $added |
      ([($before[$name].entries // [])[] |
        select(.path as $path | ($afterPaths | index($path) | not)) |
        .narSize | select(type == "number")] | add // 0) as $removed |
      {
        name: $name,
        kind: (if $before[$name] == null then "added"
               elif $after[$name] == null then "removed"
               elif $before[$name].versions != $after[$name].versions then "version"
               else "rebuild" end),
        confidence: ($after[$name].confidence // "confirmed"),
        sizeKnown: (($before[$name].sizeKnown // true) and ($after[$name].sizeKnown // true)),
        before: public($before[$name]),
        after: public($after[$name]),
        addedBytes: $added,
        removedBytes: $removed,
        deltaBytes: ($added - $removed)
      }
    ] as $changes |
    ($changes | map(select(.kind != "rebuild"))) as $packages |
    ($changes | map(select(.kind == "rebuild"))) as $rebuildChanges |
    {
      changes: $packages,
      rebuilds: {
        count: ($rebuildChanges | length),
        addedBytes: ($rebuildChanges | map(.addedBytes) | add // 0),
        removedBytes: ($rebuildChanges | map(.removedBytes) | add // 0),
        deltaBytes: (($rebuildChanges | map(.addedBytes) | add // 0)
          - ($rebuildChanges | map(.removedBytes) | add // 0)),
        sizeKnown: all($rebuildChanges[]; .sizeKnown),
        items: ($rebuildChanges | map({
          name,
          versions: (.after.versions // .before.versions // []),
          confidence
        }))
      },
      baselineClosureBytes: ($baseline[0] | to_entries | map(.value.narSize // 0) | add // 0),
      candidateClosureBytes: ($candidate[0] | to_entries | map(.value.narSize // 0) | add // 0)
    }
  ' >"$destination"
}

current_system_state() {
  running_system=$(resolved_path "$running_link")
  boot_system=$(resolved_path "$boot_link")
  [[ -n "$running_system" ]] || fail "No running NixOS system is available."
  [[ -n "$boot_system" ]] || boot_system=$running_system
  baseline_kind=running
  baseline_system=$running_system
  ready_for_boot=false
  if [[ "$boot_system" != "$running_system" ]]; then
    baseline_kind=boot
    baseline_system=$boot_system
    ready_for_boot=true
  fi
  running_generation=$(generation_number "$running_system")
  boot_generation=$(generation_number "$boot_system")
}

select_configuration() {
  local flake=$1
  local discovery_expression
  # ${name} must reach Nix literally.
  # shellcheck disable=SC2016
  discovery_expression='configs: map (name: let value = builtins.tryEval configs.${name}.config.networking.hostName; in { inherit name; hostName = if value.success then value.value else ""; }) (builtins.attrNames configs)'
  local configurations
  if ! configurations=$(nix --store "$store" eval --json --no-write-lock-file \
    --apply "$discovery_expression" "$flake#nixosConfigurations" \
    2>"$temporary_directory/configurations.log"); then
    fail "Could not enumerate NixOS configurations." "$({ cat "$temporary_directory/configurations.log"; } 2>/dev/null)"
  fi
  configuration=$(jq -r --arg hostname "$hostname" '
    if length == 1 then .[0].name
    else ([.[] | select(.hostName == $hostname)] | if length == 1 then .[0].name else empty end)
    end
  ' <<<"$configurations")
  [[ -n "$configuration" ]] || fail \
    "Could not select one NixOS configuration for host $hostname." \
    "Available configurations: $(jq -c '.' <<<"$configurations")"
}

make_input_changes() {
  local baseline_lock=$1
  local candidate_lock=$2
  local fallback_revision=$3
  local complete=$4
  local destination=$5
  jq -n \
    --slurpfile baselineLock "$baseline_lock" \
    --slurpfile candidateLock "$candidate_lock" \
    --arg fallbackRevision "$fallback_revision" \
    --argjson complete "$complete" '
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
        display: (($value.rev // $value.lastModified // $value.narHash // $value.url // "missing")
          | tostring | .[0:12])
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
      (if ($complete | not) and $name == "nixpkgs" and $fallbackRevision != "" then
        ($originalBefore + {
          revision: $fallbackRevision,
          narHash: null,
          display: $fallbackRevision[0:12]
        })
      else $originalBefore end) as $before |
      (detail($candidate; $name)) as $after |
      select(identity($before) != identity($after)) |
      {name: $name, before: $before, after: $after}
    ]
  ' >"$destination"
}

run_preview() {
  local started
  started=$(date +%s)
  current_system_state
  local flake="path:$repository"
  hostname=${NIXOS_UPDATE_CHECKER_HOSTNAME:-$(cat /proc/sys/kernel/hostname)}
  local working_lock_hash
  working_lock_hash=$(sha256_file "$repository/flake.lock")
  local candidate_lock="$temporary_directory/candidate.lock"

  log "Resolving updated configuration inputs without modifying flake.lock."
  if ! nix --store "$store" flake update --flake "$flake" \
    --output-lock-file "$candidate_lock" \
    2> >(tee "$temporary_directory/update.log" >&2); then
    fail "Could not resolve updated configuration inputs." "$({ cat "$temporary_directory/update.log"; } 2>/dev/null)"
  fi
  [[ "$working_lock_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "flake.lock changed while the preview was running."

  log "Selecting the NixOS configuration."
  select_configuration "$flake"
  local installable="$flake#nixosConfigurations.\"$configuration\""
  local system_installable="$installable.config.system.build.toplevel"
  local declared_deriver
  if ! declared_deriver=$(nix --store "$store" eval --raw --no-write-lock-file \
    "$system_installable.drvPath" 2>"$temporary_directory/declared.log"); then
    fail "Could not evaluate the configured NixOS system." "$({ cat "$temporary_directory/declared.log"; } 2>/dev/null)"
  fi
  local baseline_deriver
  baseline_deriver=$(deriver_for "$baseline_system")

  local baseline_lock="$temporary_directory/baseline.lock"
  local input_baseline_source=runningNixpkgsFallback
  local input_baseline_complete=false
  local record_system_lock=false
  if [[ -n "$baseline_deriver" && "$declared_deriver" == "$baseline_deriver" ]]; then
    install -m 0644 "$repository/flake.lock" "$baseline_lock"
    input_baseline_source=workingConfiguration
    input_baseline_complete=true
    record_system_lock=true
  elif [[ -f "$state_path" ]] && jq -e \
    --arg repository "$repository" --arg system "$baseline_system" '
      .schemaVersion == 1 and .repository == $repository and .system == $system
      and (.lock | type == "object")
    ' "$state_path" >/dev/null 2>&1; then
    jq '.lock' "$state_path" >"$baseline_lock"
    input_baseline_source=savedSystemLock
    input_baseline_complete=true
  else
    install -m 0644 "$repository/flake.lock" "$baseline_lock"
  fi

  local baseline_revision=${NIXOS_UPDATE_CHECKER_BASELINE_NIXPKGS_REVISION:-}
  if [[ -z "$baseline_revision" && -x "$baseline_system/sw/bin/nixos-version" ]]; then
    baseline_revision=$("$baseline_system/sw/bin/nixos-version" --json 2>/dev/null |
      jq -r '.nixpkgsRevision // empty' || true)
  fi
  make_input_changes "$baseline_lock" "$candidate_lock" "$baseline_revision" \
    "$input_baseline_complete" "$temporary_directory/inputs.json"

  [[ -f "$discovery_file" ]] || fail "Package discovery rules are missing at $discovery_file."
  local discovery_expression
  discovery_expression=$(<"$discovery_file")
  log "Discovering configured packages in one candidate evaluation."
  if ! nix --store "$store" eval --json --no-write-lock-file \
    --reference-lock-file "$candidate_lock" --apply "$discovery_expression" \
    "$installable" >"$temporary_directory/discovery-raw.json" \
    2> >(tee "$temporary_directory/discovery.log" >&2); then
    fail "Could not discover configured candidate packages." "$({ cat "$temporary_directory/discovery.log"; } 2>/dev/null)"
  fi
  normalise_discovery "$temporary_directory/discovery-raw.json" \
    "$temporary_directory/discovery.json"
  local candidate_deriver candidate_system
  candidate_deriver=$(jq -er '.system.drvPath' "$temporary_directory/discovery.json")
  candidate_system=$(jq -er '.system.storePath' "$temporary_directory/discovery.json")

  log "Inspecting the realized baseline closure."
  query_path_info "$store" "$temporary_directory/baseline.json" \
    "$temporary_directory/baseline-path-info.log" "$baseline_system" || \
    fail "Could not inspect the realized baseline closure." \
      "$({ cat "$temporary_directory/baseline-path-info.log"; } 2>/dev/null)"

  jq -r '.packages[].storePath' "$temporary_directory/discovery.json" | sort -u \
    >"$temporary_directory/candidate-roots.txt"
  query_candidate_metadata "$temporary_directory/candidate-roots.txt" \
    "$temporary_directory/candidate-metadata.json"

  log "Inspecting the candidate derivation graph without realizing it."
  if ! nix --store "$store" derivation show --recursive "$candidate_deriver" \
    >"$temporary_directory/candidate-graph.json" \
    2>"$temporary_directory/candidate-graph.log"; then
    fail "Could not inspect the candidate derivation graph." \
      "$({ cat "$temporary_directory/candidate-graph.log"; } 2>/dev/null)"
  fi
  add_preview_fallbacks "$temporary_directory/baseline.json" \
    "$temporary_directory/candidate-graph.json" "$temporary_directory/discovery.json" \
    "$temporary_directory/candidate-metadata.json" "$temporary_directory/candidate-preview.json"
  compare_closures "$temporary_directory/baseline.json" \
    "$temporary_directory/candidate-preview.json" "$temporary_directory/discovery.json" \
    "$temporary_directory/comparison.json"

  log "Asking Nix which derivations would require local builds."
  local dry_run_status=0
  nix --store "$store" build --dry-run --json --no-link --no-write-lock-file \
    --reference-lock-file "$candidate_lock" "$system_installable" \
    >"$temporary_directory/dry-run.json" 2>"$temporary_directory/dry-run.log" || dry_run_status=$?
  if ((dry_run_status != 0)); then
    fail "Nix could not calculate the candidate build plan." \
      "$({ cat "$temporary_directory/dry-run.log"; } 2>/dev/null)"
  fi
  grep -Eo '/nix/store/[a-z0-9]{32}-[^[:space:]]+\.drv' \
    "$temporary_directory/dry-run.log" | sort -u >"$temporary_directory/local-builds.txt" || true
  jq -Rn '[inputs | select(. != "") | {
    drvPath: .,
    name: (split("/")[-1] | sub("^[^-]+-"; "") | sub("\\.drv$"; ""))
  }]' <"$temporary_directory/local-builds.txt" >"$temporary_directory/local-builds.json"

  if [[ "$record_system_lock" == true ]]; then
    jq -n --arg repository "$repository" --arg system "$baseline_system" \
      --arg recordedAt "$(date --iso-8601=seconds)" \
      --slurpfile lock "$repository/flake.lock" '{
        schemaVersion: 1,
        repository: $repository,
        system: $system,
        recordedAt: $recordedAt,
        lock: $lock[0]
      }' >"$temporary_directory/system-lock.json"
    write_json_file "$temporary_directory/system-lock.json" "$state_path"
  fi

  local elapsed=$(( $(date +%s) - started ))
  local generated_at
  generated_at=$(date --iso-8601=seconds)
  local candidate_lock_hash
  candidate_lock_hash=$(sha256_file "$candidate_lock")
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
    --arg candidateDeriver "$candidate_deriver" \
    --arg workingLockHash "$working_lock_hash" \
    --arg candidateLockHash "$candidate_lock_hash" \
    --arg inputBaselineSource "$input_baseline_source" \
    --argjson readyForBoot "$ready_for_boot" \
    --argjson inputBaselineComplete "$input_baseline_complete" \
    --argjson elapsed "$elapsed" \
    --slurpfile inputs "$temporary_directory/inputs.json" \
    --slurpfile comparison "$temporary_directory/comparison.json" \
    --slurpfile discovery "$temporary_directory/discovery.json" \
    --slurpfile localBuilds "$temporary_directory/local-builds.json" \
    --slurpfile candidatePreview "$temporary_directory/candidate-preview.json" '
    def numberOrNull($value): if $value == "" then null else ($value | tonumber) end;
    ($comparison[0]) as $diff |
    {
      schemaVersion: 3,
      generatedAt: $generatedAt,
      status: "success",
      repository: $repository,
      configuration: $configuration,
      analysis: {
        mode: "preview",
        candidateClosureComplete: false,
        configuredPackages: ($discovery[0].packages | length),
        describedCandidatePaths: ($candidatePreview[0] | length)
      },
      candidate: {
        deriver: $candidateDeriver,
        workingLockHash: $workingLockHash,
        lockHash: $candidateLockHash
      },
      inputs: $inputs[0],
      inputBaseline: {
        source: $inputBaselineSource,
        complete: $inputBaselineComplete,
        system: $baselineSystem
      },
      discovery: $discovery[0],
      packages: {
        changes: $diff.changes,
        rebuilds: $diff.rebuilds
      },
      buildPlan: {
        localBuildCount: ($localBuilds[0] | length),
        localBuilds: $localBuilds[0]
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
        baselineClosureBytes: $diff.baselineClosureBytes,
        candidateClosureBytes: $diff.candidateClosureBytes,
        closureDeltaBytes: ($diff.candidateClosureBytes - $diff.baselineClosureBytes),
        sizeKnown: false
      },
      updatesAvailable: (($inputs[0] | length) + ($diff.changes | length)
        + ($diff.rebuilds.count // 0) > 0)
    }
  ' >"$temporary_directory/report.json"

  [[ "$working_lock_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "flake.lock changed while the preview was running."
  if [[ -n "$candidate_lock_path" ]]; then
    write_json_file "$candidate_lock" "$candidate_lock_path"
  fi
  write_report "$temporary_directory/report.json"
  log "Preview report published in ${elapsed}s without realizing the candidate."
}

run_build() {
  [[ -n "$report_path" && -f "$report_path" ]] || \
    fail "No preview report is available to build."
  [[ -n "$candidate_lock_path" && -f "$candidate_lock_path" ]] || \
    fail "No saved candidate lock is available to build."

  local preview="$temporary_directory/preview.json"
  install -m 0644 "$report_path" "$preview"
  jq -e --arg repository "$repository" '
    .schemaVersion == 3 and .status == "success" and .analysis.mode == "preview"
    and .repository == $repository and .updatesAvailable == true
  ' "$preview" >/dev/null || fail "The saved report is not a buildable preview."

  current_system_state
  local report_baseline
  report_baseline=$(jq -er '.system.baselinePath' "$preview")
  [[ "$report_baseline" == "$baseline_system" ]] || \
    fail "The system profile changed after this preview was generated. Run Refresh first."
  local expected_working_hash expected_candidate_hash
  expected_working_hash=$(jq -er '.candidate.workingLockHash' "$preview")
  expected_candidate_hash=$(jq -er '.candidate.lockHash' "$preview")
  [[ "$expected_working_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "flake.lock changed after this preview was generated. Run Refresh first."
  [[ "$expected_candidate_hash" == "$(sha256_file "$candidate_lock_path")" ]] || \
    fail "The saved candidate lock does not match the preview."

  configuration=$(jq -er '.configuration' "$preview")
  local flake="path:$repository"
  local system_installable="$flake#nixosConfigurations.\"$configuration\".config.system.build.toplevel"
  local candidate_deriver
  if ! candidate_deriver=$(nix --store "$store" eval --raw --no-write-lock-file \
    --reference-lock-file "$candidate_lock_path" "$system_installable.drvPath" \
    2>"$temporary_directory/build-eval.log"); then
    fail "Could not evaluate the saved candidate." "$({ cat "$temporary_directory/build-eval.log"; } 2>/dev/null)"
  fi
  [[ "$candidate_deriver" == "$(jq -er '.candidate.deriver' "$preview")" ]] || \
    fail "The evaluated candidate no longer matches the preview."

  local started
  started=$(date +%s)
  log "Building the reviewed candidate with normal Nix scheduling."
  local candidate_system
  if ! candidate_system=$(nix --store "$store" build --no-link --print-out-paths \
    --print-build-logs --no-write-lock-file \
    --reference-lock-file "$candidate_lock_path" "$system_installable" \
    2> >(tee "$temporary_directory/build.log" >&2)); then
    fail "Could not build the reviewed NixOS candidate." "$({ cat "$temporary_directory/build.log"; } 2>/dev/null)"
  fi
  candidate_system=$(head -n 1 <<<"$candidate_system")
  [[ "$candidate_system" == "$(jq -er '.system.candidate' "$preview")" ]] || \
    fail "The realized candidate path differs from the preview."

  log "Inspecting the verified baseline and candidate closures."
  query_path_info "$store" "$temporary_directory/baseline.json" \
    "$temporary_directory/baseline.log" "$baseline_system" || \
    fail "Could not inspect the baseline closure." "$({ cat "$temporary_directory/baseline.log"; } 2>/dev/null)"
  query_path_info "$store" "$temporary_directory/candidate.json" \
    "$temporary_directory/candidate.log" "$candidate_system" || \
    fail "Could not inspect the candidate closure." "$({ cat "$temporary_directory/candidate.log"; } 2>/dev/null)"
  jq '.discovery' "$preview" >"$temporary_directory/discovery.json"
  compare_closures "$temporary_directory/baseline.json" "$temporary_directory/candidate.json" \
    "$temporary_directory/discovery.json" "$temporary_directory/comparison.json"

  local elapsed=$(( $(date +%s) - started ))
  local verified_at
  verified_at=$(date --iso-8601=seconds)
  jq --arg generatedAt "$verified_at" --arg candidateSystem "$candidate_system" \
    --argjson elapsed "$elapsed" --slurpfile comparison "$temporary_directory/comparison.json" '
    ($comparison[0]) as $diff |
    .previewGeneratedAt = .generatedAt |
    .generatedAt = $generatedAt |
    .analysis.mode = "verified" |
    .analysis.candidateClosureComplete = true |
    .packages = {changes: $diff.changes, rebuilds: $diff.rebuilds} |
    .system.candidate = $candidateSystem |
    .build = {
      elapsedSeconds: $elapsed,
      baselineClosureBytes: $diff.baselineClosureBytes,
      candidateClosureBytes: $diff.candidateClosureBytes,
      closureDeltaBytes: ($diff.candidateClosureBytes - $diff.baselineClosureBytes),
      sizeKnown: true
    } |
    .updatesAvailable = ((.inputs | length) + ($diff.changes | length)
      + ($diff.rebuilds.count // 0) > 0)
  ' "$preview" >"$temporary_directory/verified-report.json"
  write_report "$temporary_directory/verified-report.json"
  log "Verified closure report published after a ${elapsed}s manual build."
}

while (($#)); do
  case "$1" in
    --build)
      mode=build
      shift
      ;;
    --report)
      (($# >= 2)) || { usage >&2; exit 2; }
      report_path=$2
      shift 2
      ;;
    --candidate-lock)
      (($# >= 2)) || { usage >&2; exit 2; }
      candidate_lock_path=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "nixos-update-checker-service 4.0.0"
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

[[ -f "$repository/flake.nix" ]] || fail "No flake.nix exists in $repository."
[[ -f "$repository/flake.lock" ]] || fail "This checker requires a flake.lock baseline."

if [[ "$mode" == build ]]; then
  run_build
else
  run_preview
fi
