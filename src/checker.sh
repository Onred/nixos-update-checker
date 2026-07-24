#!/usr/bin/env bash

set -Eeuo pipefail

mode=preview
finalizing=${NIXOS_UPDATE_CHECKER_FINALIZING:-false}
report_path=""
candidate_lock_path=""
preview_snapshot_path=""
verified_snapshot_path=""
status_path=${NIXOS_UPDATE_CHECKER_STATUS:-}
requested_configuration=${NIXOS_UPDATE_CHECKER_CONFIGURATION:-}
configuration=""
repository=""
temporary_directory=""
started_at=""
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
                                    [--candidate-lock PATH] [--status PATH]
                                    [--configuration NAME]
                                    [--preview-snapshot PATH]
                                    [--verified-snapshot PATH]
                                    REPOSITORY

Without --build, check for updates without building them. --build builds the
exact saved update and records complete package and size information.
EOF
}

cleanup() {
  if [[ -n "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}

stop_checker() {
  trap - TERM INT
  write_operation_status cancelled "Operation cancelled" ""
  exit 143
}

unexpected_error() {
  local exit_status=$?
  trap - ERR
  write_operation_status failed "The update check stopped unexpectedly." \
    "Open Progress for technical details."
  exit "$exit_status"
}

trap cleanup EXIT
trap stop_checker TERM INT
trap unexpected_error ERR

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

operation_name() {
  if [[ "$mode" == build ]]; then
    printf 'build\n'
  elif [[ "$finalizing" == true ]]; then
    printf 'finalize\n'
  else
    printf 'refresh\n'
  fi
}

write_operation_status() {
  local state=$1
  local message=${2:-}
  local diagnostics=${3:-}
  [[ -n "$status_path" && -n "$temporary_directory" ]] || return
  jq -n \
    --arg state "$state" \
    --arg operation "$(operation_name)" \
    --arg startedAt "$started_at" \
    --arg updatedAt "$(date --iso-8601=seconds)" \
    --arg message "$message" \
    --arg diagnostics "$diagnostics" '
    {
      schemaVersion: 1,
      state: $state,
      operation: $operation,
      startedAt: (if $startedAt == "" then null else $startedAt end),
      updatedAt: $updatedAt,
      message: $message,
      diagnostics: $diagnostics
    }
  ' >"$temporary_directory/operation-status.json"
  write_json_file "$temporary_directory/operation-status.json" "$status_path"
}

log() {
  printf 'INFO: %s\n' "$*" >&2
}

fail() {
  local message=$1
  local diagnostics=${2:-}
  local exit_status=${3:-1}
  printf 'ERROR: %s\n' "$message" >&2
  if [[ -n "$diagnostics" ]]; then
    printf '%s\n' "$diagnostics" >&2
  fi

  write_operation_status failed "$message" "$diagnostics"
  exit "$exit_status"
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
  # Nix can return a useful object containing valid entries and nulls for
  # missing paths while still exiting non-zero. Keep that partial result.
  if jq -e 'type == "object"' "$destination" >/dev/null 2>&1; then
    return
  fi
  if nix --store "$query_store" path-info --json --recursive --size \
    "$@" >"$destination" 2>"$diagnostics"; then
    return
  fi
  jq -e 'type == "object"' "$destination" >/dev/null 2>&1
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
    log "Some updated package information was unavailable in the local Nix store."
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
      log "Package information was unavailable from $query_store; trying other sources."
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

build_preview_candidates() {
  local discovery=$1
  local metadata=$2
  local destination=$3

  jq -n \
    --slurpfile discovery "$discovery" \
    --slurpfile metadata "$metadata" '
    reduce $discovery[0].packages[] as $package ($metadata[0];
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

anchor_baseline_discovery() {
  local baseline=$1
  local saved_discovery=$2
  local working_discovery=$3
  local destination=$4

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile saved "$saved_discovery" \
    --slurpfile working "$working_discovery" '
    ($baseline[0] | keys) as $baselinePaths |
    (($saved[0].packages // []) + [
      $working[0].packages[]? |
      select(.storePath as $path | ($baselinePaths | index($path)) != null)
    ]) |
    reduce .[] as $package ({};
      .[$package.storePath] = (
        if .[$package.storePath] == null then $package
        else $package + {
          sources: ((.[$package.storePath].sources + $package.sources) | unique | sort)
        } end
      )
    ) |
    {
      system: ($saved[0].system // $working[0].system // null),
      packages: ([.[]] | sort_by(.storePath))
    }
  ' >"$destination"
}

filter_preview_discovery() {
  local baseline=$1
  local discovery=$2
  local baseline_discovery=$3
  local destination=$4

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile discovery "$discovery" \
    --slurpfile baselineDiscovery "$baseline_discovery" '
    ($baseline[0] | keys) as $baselinePaths |
    (reduce (
      $baselineDiscovery[0].packages[]? |
      select(.storePath as $path | ($baselinePaths | index($path)) != null)
    ) as $package ({};
      reduce $package.sources[] as $source (.;
        .[$source] = (((.[$source] // []) + [$package.name]) | unique | sort)
      )
    )) as $activeSources |
    $discovery[0] |
    .packages |= map(
      . as $package |
      select(
        any($package.sources[]; startswith("option:") | not)
        or ($baselinePaths | index($package.storePath)) != null
        or any($package.sources[];
          . as $source |
          (($activeSources[$source] // []) | index($package.name)) != null
        )
      )
    )
  ' >"$destination"
}

compare_preview() {
  local baseline=$1
  local candidate=$2
  local baseline_discovery=$3
  local candidate_discovery=$4
  local destination=$5

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile candidate "$candidate" \
    --slurpfile baselineDiscovery "$baseline_discovery" \
    --slurpfile candidateDiscovery "$candidate_discovery" '
    def parsedIdentity($path):
      ($path | split("/")[-1] | sub("^[^-]+-"; "")) as $base |
      (try ($base | capture("^(?<name>.*?)-(?<version>[0-9].*)$")) catch null)
        // {name: $base, version: ""};
    def rootMap($discovery):
      reduce $discovery.packages[] as $package ({};
        .[$package.storePath] = $package
      );
    def identity($path; $roots):
      if $roots[$path] != null then
        {name: $roots[$path].name, version: $roots[$path].version}
      else parsedIdentity($path) end;
    def packages($closure; $roots):
      $closure | to_entries |
      map(.key as $path | (identity($path; $roots)) + {
        path: $path,
        narSize: .value.narSize,
        explicit: any($roots[$path].sources[]?; startswith("option:") | not),
        previewSource: (.value.previewSource // "confirmed")
      }) |
      sort_by(.name) | group_by(.name) |
      map({
        key: .[0].name,
        value: {
          versions: (map(.version | select(. != "")) | unique | sort),
          entries: (map({path, narSize, previewSource}) | sort_by(.path)),
          narSize: ([.[].narSize | select(type == "number")] | add // 0),
          userFacing: any(.[]; .explicit or .version != ""),
          confidence: (if any(.[]; .previewSource == "configured")
            then "configured" else "confirmed" end)
        }
      }) | from_entries;
    def public($package):
      if $package == null then null else {
        versions: $package.versions,
        paths: ($package.entries | map(.path)),
        narSize: $package.narSize,
        sizeKnown: false,
        confidence: $package.confidence
      } end;
    # Use discovered identities for roots in each system. Output suffixes
    # such as -wrapped, -sessions, and -lib32 are not package versions.
    rootMap($baselineDiscovery[0]) as $baselineRoots |
    rootMap($candidateDiscovery[0]) as $candidateRoots |
    packages($baseline[0]; $baselineRoots) as $before |
    packages($candidate[0]; $candidateRoots) as $after |
    [($after | keys[]) as $name |
      (($before[$name].entries // []) | map(.path)) as $beforePaths |
      [$after[$name].entries[] |
        select(.path as $path | ($beforePaths | index($path) | not))] as $newEntries |
      select($newEntries | length > 0) |
      (($after[$name].versions // []) - ($before[$name].versions // [])) as $introducedVersions |
      {
        name: $name,
        userFacing: (($after[$name].userFacing // false) or ($before[$name].userFacing // false)),
        kind: (if $before[$name] == null then "added"
               elif ($introducedVersions | length) > 0 then "version"
               else "rebuild" end),
        confidence: $after[$name].confidence,
        sizeKnown: false,
        before: public($before[$name]),
        after: public($after[$name]),
        addedBytes: ([$newEntries[].narSize | select(type == "number")] | add // 0),
        removedBytes: 0,
        deltaBytes: ([$newEntries[].narSize | select(type == "number")] | add // 0)
      }
    ] as $changes |
    ($changes | map(select(.userFacing))) as $visibleChanges |
    ($changes | map(select(.userFacing | not))) as $systemChanges |
    ($visibleChanges | map(select(.kind != "rebuild"))) as $packages |
    ($visibleChanges | map(select(.kind == "rebuild"))) as $rebuildChanges |
    {
      changes: $packages,
      rebuilds: {
        count: ($rebuildChanges | length),
        addedBytes: 0,
        removedBytes: 0,
        deltaBytes: 0,
        sizeKnown: false,
        items: ($rebuildChanges | map({
          name,
          versions: (.after.versions // .before.versions // []),
          confidence
        }))
      },
      system: {
        count: ($systemChanges | length),
        addedBytes: ($systemChanges | map(.addedBytes) | add // 0),
        removedBytes: 0,
        deltaBytes: ($systemChanges | map(.addedBytes) | add // 0),
        sizeKnown: false,
        items: ($systemChanges | map({name, kind}) | sort_by(.name))
      },
      baselineClosureBytes: ($baseline[0] | to_entries | map(.value.narSize // 0) | add // 0),
      candidateClosureBytes: null
    }
  ' >"$destination"
}

compare_closures() {
  local baseline=$1
  local candidate=$2
  local baseline_discovery=$3
  local candidate_discovery=$4
  local destination=$5

  jq -n \
    --slurpfile baseline "$baseline" \
    --slurpfile candidate "$candidate" \
    --slurpfile baselineDiscovery "$baseline_discovery" \
    --slurpfile candidateDiscovery "$candidate_discovery" '
    def parsedIdentity($path):
      ($path | split("/")[-1] | sub("^[^-]+-"; "")) as $base |
      (try ($base | capture("^(?<name>.*?)-(?<version>[0-9].*)$")) catch null)
        // {name: $base, version: ""};
    def rootMap($discovery):
      reduce $discovery.packages[] as $package ({};
        .[$package.storePath] = $package
      );
    def identity($path; $roots):
      if $roots[$path] != null then
        {name: $roots[$path].name, version: $roots[$path].version}
      else parsedIdentity($path) end;
    def confidence($entries):
      if any($entries[]; .previewSource == "configured") then "configured"
      else "confirmed" end;
    def packages($closure; $roots):
      $closure | to_entries |
      map(.key as $path | (identity($path; $roots)) + {
        path: $path,
        narSize: .value.narSize,
        explicit: any($roots[$path].sources[]?; startswith("option:") | not),
        previewSource: (.value.previewSource // "confirmed")
      }) |
      sort_by(.name) | group_by(.name) |
      map({
        key: .[0].name,
        value: {
          versions: (map(.version | select(. != "")) | unique | sort),
          entries: (map({path, narSize, previewSource}) | sort_by(.path)),
          narSize: ([.[].narSize | select(type == "number")] | add // 0),
          sizeKnown: all(.[]; .narSize | type == "number"),
          userFacing: any(.[]; .explicit or .version != ""),
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
    # Keep root identity symmetric instead of parsing only baseline store names.
    rootMap($baselineDiscovery[0]) as $baselineRoots |
    rootMap($candidateDiscovery[0]) as $candidateRoots |
    packages($baseline[0]; $baselineRoots) as $before |
    packages($candidate[0]; $candidateRoots) as $after |
    [((($before | keys) + ($after | keys)) | unique)[] as $name |
      (($before[$name].entries // []) | map(.path)) as $beforePaths |
      (($after[$name].entries // []) | map(.path)) as $afterPaths |
      select($beforePaths != $afterPaths) |
      (($after[$name].versions // []) - ($before[$name].versions // [])) as $introducedVersions |
      ([($after[$name].entries // [])[] |
        select(.path as $path | ($beforePaths | index($path) | not)) |
        .narSize | select(type == "number")] | add // 0) as $added |
      ([($before[$name].entries // [])[] |
        select(.path as $path | ($afterPaths | index($path) | not)) |
        .narSize | select(type == "number")] | add // 0) as $removed |
      {
        name: $name,
        userFacing: (($after[$name].userFacing // false) or ($before[$name].userFacing // false)),
        kind: (if $before[$name] == null then "added"
               elif $after[$name] == null then "removed"
               # Match preview semantics: an update introduces a version.
               elif ($introducedVersions | length) > 0 then "version"
               else "rebuild" end),
        confidence: ($after[$name].confidence // "confirmed"),
        sizeKnown: (($before[$name] == null or $before[$name].sizeKnown == true)
          and ($after[$name] == null or $after[$name].sizeKnown == true)),
        before: public($before[$name]),
        after: public($after[$name]),
        addedBytes: $added,
        removedBytes: $removed,
        deltaBytes: ($added - $removed)
      }
    ] as $changes |
    ($changes | map(select(.userFacing))) as $visibleChanges |
    ($changes | map(select(.userFacing | not))) as $systemChanges |
    ($visibleChanges | map(select(.kind != "rebuild"))) as $packages |
    ($visibleChanges | map(select(.kind == "rebuild"))) as $rebuildChanges |
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
      system: {
        count: ($systemChanges | length),
        addedBytes: ($systemChanges | map(.addedBytes) | add // 0),
        removedBytes: ($systemChanges | map(.removedBytes) | add // 0),
        deltaBytes: (($systemChanges | map(.addedBytes) | add // 0)
          - ($systemChanges | map(.removedBytes) | add // 0)),
        sizeKnown: all($systemChanges[]; .sizeKnown),
        items: ($systemChanges | map({name, kind}) | sort_by(.name))
      },
      baselineClosureBytes: ($baseline[0] | to_entries | map(.value.narSize // 0) | add // 0),
      candidateClosureBytes: ($candidate[0] | to_entries | map(.value.narSize // 0) | add // 0)
    }
  ' >"$destination"
}

current_system_state() {
  running_system=$(resolved_path "$running_link")
  boot_system=$(resolved_path "$boot_link")
  [[ -n "$running_system" ]] || fail "The running NixOS system could not be found."
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
  local names
  if ! names=$(nix --store "$store" eval --json --no-write-lock-file \
    --apply builtins.attrNames "$flake#nixosConfigurations" \
    2>"$temporary_directory/configurations.log"); then
    fail "Could not find NixOS configurations in the selected configuration folder." \
      "$({ cat "$temporary_directory/configurations.log"; } 2>/dev/null)" 2
  fi
  [[ "$(jq 'length' <<<"$names")" -gt 0 ]] || \
    fail "No NixOS configurations were found in the selected configuration folder." "" 2

  if [[ -n "$requested_configuration" ]]; then
    if jq -e --arg name "$requested_configuration" 'index($name) != null' \
      <<<"$names" >/dev/null; then
      configuration=$requested_configuration
      return
    fi
    fail "The configured NixOS configuration ($requested_configuration) was not found." \
      "Available configurations: $(jq -c '.' <<<"$names")" 2
  fi

  local saved_configuration=""
  if [[ -n "$report_path" && -f "$report_path" ]]; then
    saved_configuration=$(jq -r --arg repository "$repository" '
      select(.repository == $repository) | .configuration // empty
    ' "$report_path" 2>/dev/null || true)
  fi
  if [[ -n "$saved_configuration" ]] && \
    jq -e --arg name "$saved_configuration" 'index($name) != null' \
      <<<"$names" >/dev/null; then
    configuration=$saved_configuration
    return
  fi

  if jq -e --arg hostname "$hostname" 'index($hostname) != null' \
    <<<"$names" >/dev/null; then
    configuration=$hostname
    return
  fi

  if [[ "$(jq 'length' <<<"$names")" -eq 1 ]]; then
    configuration=$(jq -r '.[0]' <<<"$names")
    return
  fi

  local configurations_file="$temporary_directory/configurations.jsonl"
  local errors_file="$temporary_directory/configuration-errors.log"
  local name value index=0
  : >"$configurations_file"
  : >"$errors_file"
  while IFS= read -r name; do
    if value=$(nix --store "$store" eval --raw --no-write-lock-file \
      "$flake#nixosConfigurations.\"$name\".config.networking.hostName" \
      2>"$temporary_directory/configuration-$index.log"); then
      jq -nc --arg name "$name" --arg hostName "$value" \
        '{name: $name, hostName: $hostName}' >>"$configurations_file"
    else
      jq -nc --arg name "$name" \
        '{name: $name, hostName: null}' >>"$configurations_file"
      {
        printf 'Configuration %s:\n' "$name"
        cat "$temporary_directory/configuration-$index.log"
        printf '\n'
      } >>"$errors_file"
    fi
    ((index += 1))
  done < <(jq -r '.[]' <<<"$names")

  local configurations
  configurations=$(jq -s '.' "$configurations_file")
  configuration=$(jq -r --arg hostname "$hostname" '
    [.[] | select(.hostName == $hostname)] |
    if length == 1 then .[0].name else empty end
  ' <<<"$configurations")
  [[ -n "$configuration" ]] && return

  local diagnostics
  diagnostics="Available configurations: $(jq -c '.' <<<"$configurations")"
  if [[ -s "$errors_file" ]]; then
    diagnostics+=$'\n\n'
    diagnostics+=$(<"$errors_file")
  fi
  fail "Could not determine which NixOS configuration belongs to this computer." \
    "$diagnostics"$'\nSet programs.nixos-update-checker.configuration when automatic selection is ambiguous.' 2
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

  log "Checking configuration sources for updates without changing flake.lock."
  if ! nix --store "$store" flake update --flake "$flake" \
    --output-lock-file "$candidate_lock" \
    2> >(tee "$temporary_directory/update.log" >&2); then
    fail "Could not check for newer configuration sources." "$({ cat "$temporary_directory/update.log"; } 2>/dev/null)"
  fi
  [[ "$working_lock_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "Your NixOS configuration changed during the refresh. Try again." "" 2

  log "Selecting the NixOS configuration."
  select_configuration "$flake"
  local installable="$flake#nixosConfigurations.\"$configuration\""
  local system_installable="$installable.config.system.build.toplevel"

  [[ -f "$discovery_file" ]] || \
    fail "Package discovery rules are missing at $discovery_file." "" 2
  local discovery_expression
  discovery_expression=$(<"$discovery_file")
  log "Reading packages from the current configuration."
  if ! nix --store "$store" eval --json --no-write-lock-file \
    --apply "$discovery_expression" "$installable" \
    >"$temporary_directory/working-discovery-raw.json" \
    2>"$temporary_directory/declared.log"; then
    fail "Your NixOS configuration contains an error." \
      "$({ cat "$temporary_directory/declared.log"; } 2>/dev/null)" 2
  fi
  normalise_discovery "$temporary_directory/working-discovery-raw.json" \
    "$temporary_directory/working-discovery.json"
  local declared_deriver
  declared_deriver=$(jq -er '.system.drvPath' "$temporary_directory/working-discovery.json")
  local baseline_deriver
  baseline_deriver=$(deriver_for "$baseline_system")

  local baseline_lock="$temporary_directory/baseline.lock"
  local baseline_discovery="$temporary_directory/baseline-discovery.json"
  printf '{"packages":[]}\n' >"$baseline_discovery"
  local input_baseline_source=runningNixpkgsFallback
  local input_baseline_complete=false
  local record_system_lock=false
  if [[ -n "$baseline_deriver" && "$declared_deriver" == "$baseline_deriver" ]]; then
    install -m 0644 "$repository/flake.lock" "$baseline_lock"
    input_baseline_source=workingConfiguration
    input_baseline_complete=true
    record_system_lock=true
    install -m 0644 "$temporary_directory/working-discovery.json" "$baseline_discovery"
  elif [[ -f "$state_path" ]] && jq -e \
    --arg repository "$repository" --arg system "$baseline_system" '
      .schemaVersion == 1 and .repository == $repository and .system == $system
      and (.lock | type == "object")
    ' "$state_path" >/dev/null 2>&1; then
    jq '.lock' "$state_path" >"$baseline_lock"
    if jq -e '.discovery.packages | type == "array"' "$state_path" >/dev/null 2>&1; then
      jq '.discovery' "$state_path" >"$baseline_discovery"
    fi
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

  log "Reading packages from the updated configuration."
  if ! nix --store "$store" eval --json --no-write-lock-file \
    --reference-lock-file "$candidate_lock" --apply "$discovery_expression" \
    "$installable" >"$temporary_directory/discovery-raw.json" \
    2> >(tee "$temporary_directory/discovery.log" >&2); then
    fail "Could not read packages from your NixOS configuration." \
      "$({ cat "$temporary_directory/discovery.log"; } 2>/dev/null)" 2
  fi
  normalise_discovery "$temporary_directory/discovery-raw.json" \
    "$temporary_directory/discovery.json"
  local candidate_deriver candidate_system
  candidate_deriver=$(jq -er '.system.drvPath' "$temporary_directory/discovery.json")
  candidate_system=$(jq -er '.system.storePath' "$temporary_directory/discovery.json")

  log "Reading packages from the current system."
  query_path_info "$store" "$temporary_directory/baseline.json" \
    "$temporary_directory/baseline-path-info.log" "$baseline_system" || \
    fail "Could not read packages from the current system." \
      "$({ cat "$temporary_directory/baseline-path-info.log"; } 2>/dev/null)"
  anchor_baseline_discovery "$temporary_directory/baseline.json" \
    "$baseline_discovery" "$temporary_directory/working-discovery.json" \
    "$temporary_directory/anchored-baseline-discovery.json"
  baseline_discovery="$temporary_directory/anchored-baseline-discovery.json"

  local analysis_mode=preview
  local candidate_closure_complete=false
  local build_size_known=false
  local candidate_data="$temporary_directory/candidate-preview.json"
  if [[ "$candidate_system" == "$baseline_system" ]]; then
    log "The available update matches the current system; reusing its package information."
    install -m 0644 "$temporary_directory/baseline.json" "$candidate_data"
    compare_closures "$temporary_directory/baseline.json" "$candidate_data" \
      "$baseline_discovery" "$temporary_directory/discovery.json" \
      "$temporary_directory/comparison.json"
    analysis_mode=verified
    candidate_closure_complete=true
    build_size_known=true
    : >"$temporary_directory/local-builds.txt"
  elif [[ -e "$candidate_system" ]]; then
    log "The update is already built; reading its package information."
    query_path_info "$store" "$candidate_data" \
      "$temporary_directory/candidate-path-info.log" "$candidate_system" || \
      fail "Could not read packages from the available update." \
        "$({ cat "$temporary_directory/candidate-path-info.log"; } 2>/dev/null)"
    compare_closures "$temporary_directory/baseline.json" "$candidate_data" \
      "$baseline_discovery" "$temporary_directory/discovery.json" \
      "$temporary_directory/comparison.json"
    analysis_mode=verified
    candidate_closure_complete=true
    build_size_known=true
    : >"$temporary_directory/local-builds.txt"
  else
    filter_preview_discovery "$temporary_directory/baseline.json" \
      "$temporary_directory/discovery.json" "$baseline_discovery" \
      "$temporary_directory/preview-discovery.json"
    local discovered_count preview_count
    discovered_count=$(jq '.packages | length' "$temporary_directory/discovery.json")
    preview_count=$(jq '.packages | length' "$temporary_directory/preview-discovery.json")
    log "Using $preview_count of $discovered_count safe package roots for the preview."
    jq -r '.packages[].storePath' "$temporary_directory/preview-discovery.json" | sort -u \
      >"$temporary_directory/candidate-roots.txt"
    query_candidate_metadata "$temporary_directory/candidate-roots.txt" \
      "$temporary_directory/candidate-metadata.json"
    build_preview_candidates "$temporary_directory/preview-discovery.json" \
      "$temporary_directory/candidate-metadata.json" "$candidate_data"
    compare_preview "$temporary_directory/baseline.json" "$candidate_data" \
      "$baseline_discovery" "$temporary_directory/preview-discovery.json" \
      "$temporary_directory/comparison.json"

    log "Checking which parts of the update need to be built on this computer."
    local dry_run_status=0
    nix --store "$store" build --dry-run --json --no-link --no-write-lock-file \
      --reference-lock-file "$candidate_lock" "$system_installable" \
      >"$temporary_directory/dry-run.json" 2>"$temporary_directory/dry-run.log" || dry_run_status=$?
    if ((dry_run_status != 0)); then
      fail "Nix could not calculate what the update needs to build." \
        "$({ cat "$temporary_directory/dry-run.log"; } 2>/dev/null)" 2
    fi
    grep -Eo '/nix/store/[a-z0-9]{32}-[^[:space:]]+\.drv' \
      "$temporary_directory/dry-run.log" | sort -u >"$temporary_directory/local-builds.txt" || true
  fi
  jq -Rn '[inputs | select(. != "") | {
    drvPath: .,
    name: (split("/")[-1] | sub("^[^-]+-"; "") | sub("\\.drv$"; ""))
  }]' <"$temporary_directory/local-builds.txt" >"$temporary_directory/local-builds.json"

  if [[ "$record_system_lock" == true ]]; then
    jq -n --arg repository "$repository" --arg system "$baseline_system" \
      --arg recordedAt "$(date --iso-8601=seconds)" \
      --slurpfile lock "$repository/flake.lock" \
      --slurpfile discovery "$temporary_directory/working-discovery.json" '{
        schemaVersion: 1,
        repository: $repository,
        system: $system,
        recordedAt: $recordedAt,
        lock: $lock[0],
        discovery: $discovery[0]
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
    --arg analysisMode "$analysis_mode" \
    --arg inputBaselineSource "$input_baseline_source" \
    --argjson readyForBoot "$ready_for_boot" \
    --argjson inputBaselineComplete "$input_baseline_complete" \
    --argjson candidateClosureComplete "$candidate_closure_complete" \
    --argjson buildSizeKnown "$build_size_known" \
    --argjson elapsed "$elapsed" \
    --slurpfile inputs "$temporary_directory/inputs.json" \
    --slurpfile comparison "$temporary_directory/comparison.json" \
    --slurpfile baselineDiscovery "$baseline_discovery" \
    --slurpfile discovery "$temporary_directory/discovery.json" \
    --slurpfile localBuilds "$temporary_directory/local-builds.json" \
    --slurpfile candidatePreview "$candidate_data" '
    def numberOrNull($value): if $value == "" then null else ($value | tonumber) end;
    ($comparison[0]) as $diff |
    {
      schemaVersion: 3,
      generatedAt: $generatedAt,
      status: "success",
      repository: $repository,
      configuration: $configuration,
      analysis: {
        mode: $analysisMode,
        candidateClosureComplete: $candidateClosureComplete,
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
      baselineDiscovery: $baselineDiscovery[0],
      discovery: $discovery[0],
      packages: {
        changes: $diff.changes,
        rebuilds: $diff.rebuilds,
        system: $diff.system
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
        closureDeltaBytes: (if ($diff.candidateClosureBytes | type) == "number"
          then $diff.candidateClosureBytes - $diff.baselineClosureBytes else null end),
        sizeKnown: $buildSizeKnown
      },
      updatesAvailable: (($inputs[0] | length) + ($diff.changes | length)
        + ($diff.rebuilds.count // 0) + ($diff.system.count // 0) > 0)
    }
  ' >"$temporary_directory/report.json"

  [[ "$working_lock_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "Your NixOS configuration changed during the refresh. Try again." "" 2
  if [[ -n "$candidate_lock_path" ]]; then
    write_json_file "$candidate_lock" "$candidate_lock_path"
  fi
  write_report "$temporary_directory/report.json"
  if [[ "$finalizing" == true ]]; then
    write_operation_status succeeded "Update finished" ""
  else
    write_operation_status succeeded "Update check finished" ""
  fi
  if [[ "$analysis_mode" == verified ]]; then
    log "Complete update information saved in ${elapsed}s; the update was already built."
  else
    log "Update preview saved in ${elapsed}s without building the update."
  fi
}

run_build() {
  [[ -n "$report_path" && -f "$report_path" ]] || \
    fail "Refresh before building the update."
  [[ -n "$candidate_lock_path" && -f "$candidate_lock_path" ]] || \
    fail "The saved update information is missing. Refresh and try again."

  local preview="$temporary_directory/preview.json"
  install -m 0644 "$report_path" "$preview"
  jq -e --arg repository "$repository" '
    .schemaVersion == 3 and .status == "success" and .analysis.mode == "preview"
    and .repository == $repository and .updatesAvailable == true
  ' "$preview" >/dev/null || fail "This update is not ready to build. Refresh and try again."

  current_system_state
  local report_baseline
  report_baseline=$(jq -er '.system.baselinePath' "$preview")
  [[ "$report_baseline" == "$baseline_system" ]] || \
    fail "Your system changed since the last refresh. Refresh and try again."
  local expected_working_hash expected_candidate_hash
  expected_working_hash=$(jq -er '.candidate.workingLockHash' "$preview")
  expected_candidate_hash=$(jq -er '.candidate.lockHash' "$preview")
  [[ "$expected_working_hash" == "$(sha256_file "$repository/flake.lock")" ]] || \
    fail "Your NixOS configuration changed since the last refresh. Refresh and try again."
  [[ "$expected_candidate_hash" == "$(sha256_file "$candidate_lock_path")" ]] || \
    fail "The saved update is no longer valid. Refresh and try again."

  configuration=$(jq -er '.configuration' "$preview")
  local flake="path:$repository"
  local system_installable="$flake#nixosConfigurations.\"$configuration\".config.system.build.toplevel"
  local candidate_deriver
  if ! candidate_deriver=$(nix --store "$store" eval --raw --no-write-lock-file \
    --reference-lock-file "$candidate_lock_path" "$system_installable.drvPath" \
    2>"$temporary_directory/build-eval.log"); then
    fail "The saved update could not be checked." "$({ cat "$temporary_directory/build-eval.log"; } 2>/dev/null)"
  fi
  [[ "$candidate_deriver" == "$(jq -er '.candidate.deriver' "$preview")" ]] || \
    fail "Your NixOS configuration changed. Refresh and try again."

  local started
  started=$(date +%s)
  log "Building the selected update with normal Nix scheduling."
  local candidate_system
  if ! candidate_system=$(nix --store "$store" build --no-link --print-out-paths \
    --print-build-logs --no-write-lock-file \
    --reference-lock-file "$candidate_lock_path" "$system_installable" \
    2> >(tee "$temporary_directory/build.log" >&2)); then
    fail "NixOS could not build the update." "$({ cat "$temporary_directory/build.log"; } 2>/dev/null)"
  fi
  candidate_system=$(head -n 1 <<<"$candidate_system")
  [[ "$candidate_system" == "$(jq -er '.system.candidate' "$preview")" ]] || \
    fail "The built update differs from the preview. Refresh and try again."

  log "Reading packages from the current system and the built update."
  query_path_info "$store" "$temporary_directory/baseline.json" \
    "$temporary_directory/baseline.log" "$baseline_system" || \
    fail "Could not read packages from the current system after the build." "$({ cat "$temporary_directory/baseline.log"; } 2>/dev/null)"
  query_path_info "$store" "$temporary_directory/candidate.json" \
    "$temporary_directory/candidate.log" "$candidate_system" || \
    fail "Could not read packages from the built update." "$({ cat "$temporary_directory/candidate.log"; } 2>/dev/null)"
  jq '.discovery' "$preview" >"$temporary_directory/discovery.json"
  jq '.baselineDiscovery // {packages: []}' "$preview" \
    >"$temporary_directory/baseline-discovery.json"
  compare_closures "$temporary_directory/baseline.json" "$temporary_directory/candidate.json" \
    "$temporary_directory/baseline-discovery.json" "$temporary_directory/discovery.json" \
    "$temporary_directory/comparison.json"

  local elapsed=$(( $(date +%s) - started ))
  local verified_at
  verified_at=$(date --iso-8601=seconds)
  jq --arg generatedAt "$verified_at" --arg candidateSystem "$candidate_system" \
    --argjson elapsed "$elapsed" --slurpfile comparison "$temporary_directory/comparison.json" '
    def packageNames($packages):
      (([$packages.changes[].name] + [$packages.rebuilds.items[].name]
        + [$packages.system.items[].name]) | unique | sort);
    ($comparison[0]) as $diff |
    packageNames(.packages) as $previewNames |
    packageNames($diff) as $verifiedNames |
    .previewGeneratedAt = .generatedAt |
    .generatedAt = $generatedAt |
    .analysis.mode = "verified" |
    .analysis.candidateClosureComplete = true |
    .analysis.previewComparison = {
      previewCount: ($previewNames | length),
      verifiedCount: ($verifiedNames | length),
      matched: ($previewNames - ($previewNames - $verifiedNames)),
      missedByPreview: ($verifiedNames - $previewNames),
      previewOnly: ($previewNames - $verifiedNames)
    } |
    .packages = {changes: $diff.changes, rebuilds: $diff.rebuilds, system: $diff.system} |
    .system.candidate = $candidateSystem |
    .build = {
      elapsedSeconds: $elapsed,
      baselineClosureBytes: $diff.baselineClosureBytes,
      candidateClosureBytes: $diff.candidateClosureBytes,
      closureDeltaBytes: ($diff.candidateClosureBytes - $diff.baselineClosureBytes),
      sizeKnown: true
    } |
    .updatesAvailable = ((.inputs | length) + ($diff.changes | length)
      + ($diff.rebuilds.count // 0) + ($diff.system.count // 0) > 0)
  ' "$preview" >"$temporary_directory/verified-report.json"
  if [[ -n "$preview_snapshot_path" ]]; then
    write_json_file "$preview" "$preview_snapshot_path"
  fi
  if [[ -n "$verified_snapshot_path" ]]; then
    write_json_file "$temporary_directory/verified-report.json" "$verified_snapshot_path"
  fi
  write_report "$temporary_directory/verified-report.json"
  write_operation_status succeeded "Update is ready to install" ""
  log "The update is ready to install after a ${elapsed}s build."
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
    --preview-snapshot)
      (($# >= 2)) || { usage >&2; exit 2; }
      preview_snapshot_path=$2
      shift 2
      ;;
    --verified-snapshot)
      (($# >= 2)) || { usage >&2; exit 2; }
      verified_snapshot_path=$2
      shift 2
      ;;
    --status)
      (($# >= 2)) || { usage >&2; exit 2; }
      status_path=$2
      shift 2
      ;;
    --configuration)
      (($# >= 2)) || { usage >&2; exit 2; }
      requested_configuration=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "nixos-update-checker-service 4.1.11"
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

started_at=$(date --iso-8601=seconds)
write_operation_status running "Operation started" ""

[[ -f "$repository/flake.nix" ]] || fail "No flake.nix exists in $repository." "" 2
[[ -f "$repository/flake.lock" ]] || fail "This checker requires a flake.lock baseline." "" 2

if [[ "$mode" == build ]]; then
  run_build
else
  run_preview
fi
