from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION

JsonObject = dict[str, Any]


class SettingsError(ValueError):
    """Raised when repository settings are invalid."""


class ConfigurationSelectionError(ValueError):
    """Raised when the running configuration cannot be selected uniquely."""


@dataclass(frozen=True)
class ConfigurationCandidate:
    name: str
    hostname: str = ""


def select_current_configuration(
    candidates: Iterable[ConfigurationCandidate], running_hostname: str
) -> str:
    available = list(candidates)
    if not available:
        raise ConfigurationSelectionError("This flake exports no nixosConfigurations.")
    if len(available) == 1:
        return available[0].name

    matches = [candidate.name for candidate in available if candidate.hostname == running_hostname]
    details = "\n".join(
        [
            f"Running hostname: {running_hostname}",
            "Available configurations:",
            *[
                f"  {candidate.name} ({candidate.hostname or 'no hostname'})"
                for candidate in available
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


OPTION_PATH = re.compile(r"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$")


@dataclass
class RepositorySettings:
    package_options: list[str] = field(default_factory=list)
    background_build: bool = False
    garbage_collection_enabled: bool = False
    garbage_collection_older_than_days: int = 30

    @classmethod
    def from_json(cls, value: JsonObject) -> RepositorySettings:
        if value.get("schemaVersion") != SCHEMA_VERSION or not isinstance(
            value.get("packageOptions"), list
        ):
            raise SettingsError("Expected schemaVersion 1 and a packageOptions array.")

        package_options = value["packageOptions"]
        if not all(
            isinstance(option, str) and OPTION_PATH.fullmatch(option) for option in package_options
        ):
            raise SettingsError("packageOptions contains an invalid NixOS option path.")

        background_build = value.get("backgroundBuild", False)
        if not isinstance(background_build, bool):
            raise SettingsError("backgroundBuild must be true or false.")

        garbage_collection = value.get("garbageCollection", {})
        if not isinstance(garbage_collection, dict):
            raise SettingsError("garbageCollection must be an object.")
        garbage_collection_enabled = garbage_collection.get("enabled", False)
        if not isinstance(garbage_collection_enabled, bool):
            raise SettingsError("garbageCollection.enabled must be true or false.")
        older_than_days = garbage_collection.get("olderThanDays", 30)
        if (
            isinstance(older_than_days, bool)
            or not isinstance(older_than_days, int)
            or not 1 <= older_than_days <= 3650
        ):
            raise SettingsError("garbageCollection.olderThanDays must be between 1 and 3650.")

        return cls(
            package_options=sorted(set(package_options)),
            background_build=background_build,
            garbage_collection_enabled=garbage_collection_enabled,
            garbage_collection_older_than_days=older_than_days,
        )

    def to_json(self) -> JsonObject:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "packageOptions": sorted(set(self.package_options)),
            "backgroundBuild": self.background_build,
            "garbageCollection": {
                "enabled": self.garbage_collection_enabled,
                "olderThanDays": self.garbage_collection_older_than_days,
            },
        }


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


def nix_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


def interactive_check_arguments(repository: str, *, real_build: bool) -> list[str]:
    arguments = ["--json", "--no-limit"]
    if real_build:
        arguments.append("--build")
    return [*arguments, repository]


def garbage_collection_arguments(older_than_days: int) -> list[str]:
    return ["--delete-older-than", f"{older_than_days}d"]


def input_identity(node: JsonObject) -> str:
    locked = node.get("locked", {})
    return ":".join(str(locked[key]) for key in ("rev", "narHash", "url") if locked.get(key))


def input_details(node: JsonObject) -> JsonObject:
    locked = node.get("locked", {})
    display = next(
        (str(locked[key]) for key in ("rev", "narHash", "url") if locked.get(key)), "missing"
    )
    if len(display) > 12:
        display = display[:8]
    return {
        "revision": locked.get("rev"),
        "narHash": locked.get("narHash"),
        "url": locked.get("url"),
        "lastModified": locked.get("lastModified"),
        "display": display,
    }


def compare_inputs(current_lock: JsonObject, candidate_lock: JsonObject) -> list[JsonObject]:
    current = current_lock.get("nodes", {})
    candidate = candidate_lock.get("nodes", {})
    changes: list[JsonObject] = []
    for name in sorted(set(current) | set(candidate)):
        before = current.get(name, {})
        after = candidate.get(name, {})
        if input_identity(before) != input_identity(after):
            changes.append(
                {
                    "name": name,
                    "before": input_details(before),
                    "after": input_details(after),
                }
            )
    return changes


def package_key(package: JsonObject) -> str:
    pname = str(package.get("pname") or "")
    if pname:
        return pname
    path = str(package.get("path") or "")
    if path:
        parsed_name = parse_store_path(path).name
        if parsed_name:
            return parsed_name
    return str(package.get("name") or "")


def package_version_identity(package: JsonObject) -> str:
    version = str(package.get("version") or "")
    if version:
        return version
    path = str(package.get("path") or "")
    if path:
        parsed_version = parse_store_path(path).version
        if parsed_version:
            return parsed_version
    return "unknown"


def collect_packages(manifest: JsonObject, selected: list[JsonObject]) -> dict[str, JsonObject]:
    packages: dict[str, JsonObject] = {}

    def append(values: Iterable[JsonObject]) -> None:
        for package in values:
            key = package_key(package)
            if key:
                packages[key] = package

    append(manifest.get("activeOptionPackages", []))
    append(manifest.get("systemPackages", []))
    append(manifest.get("corePackages", []))
    for values in manifest.get("userPackages", {}).values():
        append(values)
    append(selected)
    return packages


def package_details(package: JsonObject) -> JsonObject:
    path = str(package.get("path", ""))
    match = re.match(r"^/nix/store/([^-]+)-", path)
    return {
        "name": package.get("name"),
        "pname": package.get("pname"),
        "version": package_version_identity(package),
        "description": package.get("description"),
        "channel": package.get("channel"),
        "path": path,
        "storeHash": match.group(1)[:8] if match else "unknown",
    }


def compare_packages(
    current: dict[str, JsonObject], candidate: dict[str, JsonObject]
) -> list[JsonObject]:
    changes: list[JsonObject] = []
    for name in sorted(set(current) | set(candidate)):
        before = current.get(name)
        after = candidate.get(name)
        if (before or {}).get("path") == (after or {}).get("path"):
            continue
        if before is None:
            kind = "added"
        elif after is None:
            kind = "removed"
        elif package_version_identity(before) != package_version_identity(after):
            kind = "version"
        else:
            kind = "store"
        changes.append(
            {
                "name": name,
                "kind": kind,
                "before": package_details(before) if before else None,
                "after": package_details(after) if after else None,
            }
        )
    return changes


def package_aliases(package: JsonObject) -> set[str]:
    aliases = {package_key(package)}
    path = str(package.get("path", ""))
    if path:
        aliases.add(parse_store_path(path).name)
    return {alias for alias in aliases if alias}


def packages_matching_closure(
    packages: Iterable[JsonObject], closure: ClosureInformation
) -> list[JsonObject]:
    closure_names = set(closure.packages)
    return [package for package in packages if package_aliases(package) & closure_names]


def compare_packages_to_closure(
    baseline: ClosureInformation,
    current: dict[str, JsonObject],
    candidate: dict[str, JsonObject],
) -> list[JsonObject]:
    changes: list[JsonObject] = []
    for name in sorted(set(current) | set(candidate)):
        before_package = current.get(name)
        after_package = candidate.get(name)
        aliases: set[str] = set()
        if before_package:
            aliases.update(package_aliases(before_package))
        if after_package:
            aliases.update(package_aliases(after_package))
        before_entries = [entry for alias in aliases for entry in baseline.packages.get(alias, [])]
        before_paths = {entry.identity.path for entry in before_entries}
        after_path = str((after_package or {}).get("path", ""))
        if after_path and after_path in before_paths:
            continue
        if after_package is None:
            if not before_entries:
                continue
            kind = "removed"
        elif not before_entries:
            kind = "added"
        elif package_version_identity(after_package) not in {
            entry.identity.version or "unknown" for entry in before_entries
        }:
            kind = "version"
        else:
            kind = "store"
        changes.append(
            {
                "name": name,
                "kind": kind,
                "before": (
                    _closure_package_details(name, before_entries) if before_entries else None
                ),
                "after": package_details(after_package) if after_package else None,
            }
        )
    return changes


def partition_priority_changes(
    changes: list[JsonObject], priority_packages: Iterable[JsonObject]
) -> tuple[list[JsonObject], list[JsonObject]]:
    priority_names: set[str] = set()
    priority_paths: set[str] = set()
    for package in priority_packages:
        priority_names.update(package_aliases(package))
        path = str(package.get("path", ""))
        if path:
            priority_paths.add(path)

    primary: list[JsonObject] = []
    dependencies: list[JsonObject] = []
    for change in changes:
        change_paths: set[str] = set()
        for side in (change.get("before"), change.get("after")):
            if not isinstance(side, dict):
                continue
            path = str(side.get("path", ""))
            if path:
                change_paths.add(path)
            change_paths.update(str(value) for value in side.get("paths", []))
        if str(change.get("name", "")) in priority_names or change_paths & priority_paths:
            primary.append(change)
        else:
            dependencies.append(change)
    return primary, dependencies


def enrich_package_changes(
    changes: list[JsonObject], packages: Iterable[JsonObject]
) -> list[JsonObject]:
    metadata: dict[str, JsonObject] = {}
    for package in packages:
        for alias in package_aliases(package):
            metadata[alias] = package
    for change in changes:
        selected_package = metadata.get(str(change.get("name", "")))
        description = str((selected_package or {}).get("description") or "")
        if description:
            change["description"] = description
        channel = str((selected_package or {}).get("channel") or "")
        if channel:
            change["channel"] = channel
    return changes


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
        for path, details in value.items():
            identity = parse_store_path(path)
            if not identity.name:
                continue
            nar_size = int(details.get("narSize", 0))
            result.packages.setdefault(identity.name, []).append(ClosureEntry(identity, nar_size))
            result.paths.add(path)
            result.nar_size += nar_size
        return result


def _closure_versions(entries: list[ClosureEntry]) -> str:
    return ", ".join(sorted({entry.identity.version or "unversioned" for entry in entries}))


def _closure_package_details(name: str, entries: list[ClosureEntry]) -> JsonObject:
    paths = sorted({entry.identity.path for entry in entries})
    return {
        "name": name,
        "pname": name,
        "version": _closure_versions(entries),
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
        before_paths = {entry.identity.path for entry in before}
        after_paths = {entry.identity.path for entry in after}
        if before_paths == after_paths:
            continue
        if not before:
            kind = "added"
        elif not after:
            kind = "removed"
        elif _closure_versions(before) != _closure_versions(after):
            kind = "version"
        else:
            kind = "store"
        changes.append(
            {
                "name": name,
                "kind": kind,
                "before": _closure_package_details(name, before) if before else None,
                "after": _closure_package_details(name, after) if after else None,
            }
        )
    return changes


def package_summary(changes: list[JsonObject]) -> JsonObject:
    meaningful = [change for change in changes if change.get("kind") != "store"]
    return {
        "total": len(meaningful),
        "versions": sum(change.get("kind") == "version" for change in meaningful),
        "additions": sum(change.get("kind") == "added" for change in meaningful),
        "removals": sum(change.get("kind") == "removed" for change in meaningful),
        "storeOnly": len(changes) - len(meaningful),
    }


def split_package_changes(
    changes: list[JsonObject],
) -> tuple[list[JsonObject], list[JsonObject]]:
    meaningful = [change for change in changes if change.get("kind") != "store"]
    store_only = [change for change in changes if change.get("kind") == "store"]
    return meaningful, store_only
