from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

JsonObject = dict[str, Any]


class ConfigurationSelectionError(ValueError):
    """Raised when the running configuration cannot be selected uniquely."""


@dataclass(frozen=True)
class ConfigurationCandidate:
    name: str
    hostname: str = ""


def select_current_configuration(
    candidates: list[ConfigurationCandidate], running_hostname: str
) -> str:
    if not candidates:
        raise ConfigurationSelectionError("This flake exports no nixosConfigurations.")
    if len(candidates) == 1:
        return candidates[0].name
    matches = [candidate.name for candidate in candidates if candidate.hostname == running_hostname]
    details = "\n".join(
        [
            f"Running hostname: {running_hostname}",
            "Available configurations:",
            *[
                f"  {candidate.name} ({candidate.hostname or 'no hostname'})"
                for candidate in candidates
            ],
        ]
    )
    if not matches:
        raise ConfigurationSelectionError(
            f"No NixOS configuration matches the running system.\n{details}"
        )
    if len(matches) > 1:
        raise ConfigurationSelectionError(
            f"More than one NixOS configuration matches the running system.\n{details}"
        )
    return matches[0]


@dataclass(frozen=True)
class BuildParallelism:
    logical_cpus: int
    worker_budget: int
    max_jobs: int
    cores_per_job: int
    substitution_jobs: int


def choose_parallelism(logical_cpus: int | None) -> BuildParallelism:
    """Choose a bounded, approximately square Nix job/thread allocation."""
    available = max(1, logical_cpus or 1)
    budget = min(available, 32)
    max_jobs = max(1, math.isqrt(budget))
    cores_per_job = max(1, budget // max_jobs)
    return BuildParallelism(
        logical_cpus=available,
        worker_budget=budget,
        max_jobs=max_jobs,
        cores_per_job=cores_per_job,
        substitution_jobs=min(max_jobs, 4),
    )


@dataclass(frozen=True)
class StorePathIdentity:
    path: str
    name: str
    version: str = ""


def parse_store_path(path: str) -> StorePathIdentity:
    basename = Path(path).name
    if "-" in basename:
        basename = basename.split("-", 1)[1]
    match = re.search(r"-(?=\d)", basename)
    if match is None:
        return StorePathIdentity(path, basename)
    return StorePathIdentity(path, basename[: match.start()], basename[match.end() :])


@dataclass(frozen=True)
class ClosureEntry:
    identity: StorePathIdentity
    nar_size: int


@dataclass
class ClosureInformation:
    packages: dict[str, list[ClosureEntry]] = field(default_factory=dict)
    paths: set[str] = field(default_factory=set)
    nar_size: int = 0

    @classmethod
    def from_path_info(cls, value: JsonObject) -> ClosureInformation:
        result = cls()
        for path, raw_details in value.items():
            if not isinstance(raw_details, dict):
                continue
            identity = parse_store_path(path)
            if not identity.name:
                continue
            nar_size = int(raw_details.get("narSize", 0))
            result.packages.setdefault(identity.name, []).append(ClosureEntry(identity, nar_size))
            result.paths.add(path)
            result.nar_size += nar_size
        return result


def _versions(entries: list[ClosureEntry]) -> str:
    return ", ".join(sorted({entry.identity.version or "unversioned" for entry in entries}))


def _package_details(name: str, entries: list[ClosureEntry]) -> JsonObject:
    paths = sorted({entry.identity.path for entry in entries})
    return {
        "name": name,
        "version": _versions(entries),
        "path": paths[0] if paths else "",
        "paths": paths,
        "narSize": sum(entry.nar_size for entry in entries),
    }


def compare_closures(
    current: ClosureInformation, candidate: ClosureInformation
) -> list[JsonObject]:
    changes: list[JsonObject] = []
    for name in sorted(set(current.packages) | set(candidate.packages)):
        before = current.packages.get(name, [])
        after = candidate.packages.get(name, [])
        if {entry.identity.path for entry in before} == {entry.identity.path for entry in after}:
            continue
        if not before:
            kind = "added"
        elif not after:
            kind = "removed"
        elif _versions(before) != _versions(after):
            kind = "version"
        else:
            kind = "store"
        changes.append(
            {
                "name": name,
                "kind": kind,
                "before": _package_details(name, before) if before else None,
                "after": _package_details(name, after) if after else None,
            }
        )
    return changes


def split_package_changes(
    changes: list[JsonObject],
) -> tuple[list[JsonObject], list[JsonObject]]:
    return (
        [change for change in changes if change.get("kind") != "store"],
        [change for change in changes if change.get("kind") == "store"],
    )


def package_summary(changes: list[JsonObject]) -> JsonObject:
    meaningful, store_only = split_package_changes(changes)
    return {
        "total": len(meaningful),
        "versions": sum(change.get("kind") == "version" for change in meaningful),
        "additions": sum(change.get("kind") == "added" for change in meaningful),
        "removals": sum(change.get("kind") == "removed" for change in meaningful),
        "storeOnly": len(store_only),
    }


def nix_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


def input_identity(node: JsonObject) -> str:
    locked = node.get("locked", {})
    if not isinstance(locked, dict):
        return ""
    return ":".join(str(locked[key]) for key in ("rev", "narHash", "url") if locked.get(key))


def input_details(node: JsonObject) -> JsonObject:
    locked = node.get("locked", {})
    if not isinstance(locked, dict):
        locked = {}
    display = next(
        (str(locked[key]) for key in ("rev", "narHash", "url") if locked.get(key)),
        "missing",
    )
    return {
        "revision": locked.get("rev"),
        "narHash": locked.get("narHash"),
        "url": locked.get("url"),
        "lastModified": locked.get("lastModified"),
        "display": display[:8] if len(display) > 12 else display,
    }


def compare_inputs(current_lock: JsonObject, candidate_lock: JsonObject) -> list[JsonObject]:
    current = current_lock.get("nodes", {})
    candidate = candidate_lock.get("nodes", {})
    if not isinstance(current, dict) or not isinstance(candidate, dict):
        return []
    changes: list[JsonObject] = []
    for name in sorted(set(current) | set(candidate)):
        before = current.get(name, {})
        after = candidate.get(name, {})
        before = before if isinstance(before, dict) else {}
        after = after if isinstance(after, dict) else {}
        if input_identity(before) != input_identity(after):
            changes.append(
                {
                    "name": name,
                    "before": input_details(before),
                    "after": input_details(after),
                }
            )
    return changes


def garbage_collection_arguments(days: int) -> list[str]:
    return ["--delete-older-than", f"{max(1, min(days, 3650))}d"]
