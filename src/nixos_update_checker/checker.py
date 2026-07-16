from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, NoReturn

from . import SCHEMA_VERSION, __version__, build_revision, display_version
from .logic import (
    ClosureInformation,
    ConfigurationCandidate,
    ConfigurationSelectionError,
    JsonObject,
    RepositorySettings,
    SettingsError,
    collect_packages,
    compare_closures,
    compare_inputs,
    compare_packages_to_closure,
    enrich_package_changes,
    nix_quote,
    package_summary,
    packages_matching_closure,
    partition_priority_changes,
    select_current_configuration,
    split_package_changes,
)


class CheckerError(RuntimeError):
    def __init__(self, message: str, diagnostics: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.diagnostics = diagnostics


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def succeeded(self) -> bool:
        return self.returncode == 0


@dataclass
class CheckOptions:
    repository: str
    cpu_quota: str = "25%"
    report_path: str = "/var/lib/nixos-update-checker/report.json"
    build: bool = False
    inspect_packages: bool = True
    json_output: bool = False
    debug: bool = False
    limit_resources: bool = True
    service: bool = False


@dataclass
class SelectedPackages:
    packages: list[JsonObject]
    resolved_options: set[str]


def environment(name: str, fallback: str = "") -> str:
    return os.environ.get(name) or fallback


def nix_executable() -> str:
    return environment("NIXOS_UPDATE_CHECKER_NIX", "nix")


def manifest_evaluator_path() -> Path:
    configured = environment("NIXOS_UPDATE_CHECKER_MANIFEST")
    if configured:
        path = Path(configured)
    else:
        path = Path(__file__).resolve().parents[2] / "nix" / "manifest.nix"
    if not path.is_file():
        raise CheckerError(f"Could not find the bundled package manifest evaluator: {path}")
    return path


def run_command(program: str, arguments: list[str], *, cwd: Path | None = None) -> CommandResult:
    try:
        completed = subprocess.run(
            [program, *arguments],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        return CommandResult(127, "", str(error))
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def require_success(result: CommandResult, message: str) -> None:
    if result.succeeded:
        return
    raise CheckerError(message, (result.stderr or result.stdout).strip())


def parse_json(data: str, context: str) -> Any:
    try:
        return json.loads(data)
    except json.JSONDecodeError as error:
        raise CheckerError(context, str(error)) from error


def read_json_object(path: Path, context: str) -> JsonObject:
    try:
        value = parse_json(path.read_text(), context)
    except OSError as error:
        raise CheckerError(context, str(error)) from error
    if not isinstance(value, dict):
        raise CheckerError(context, "Expected a JSON object.")
    return value


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise CheckerError(f"Could not hash {path}", str(error)) from error
    return digest.hexdigest()


def current_hostname() -> str:
    try:
        hostname = Path("/proc/sys/kernel/hostname").read_text().strip()
    except OSError as error:
        raise CheckerError(
            "Could not determine the running system hostname.", str(error)
        ) from error
    if not hostname:
        raise CheckerError("The running system hostname is empty.")
    return hostname


DISCOVERY_APPLY = r"""
configs:
map
  (name:
    let
      result = builtins.tryEval configs.${name}.config.networking.hostName;
    in
    {
      inherit name;
      hostName = if result.success then result.value else "";
    })
  (builtins.attrNames configs)
"""


def discover_configuration(flake_reference: str, hostname: str) -> str:
    result = run_command(
        nix_executable(),
        [
            "eval",
            "--json",
            "--apply",
            DISCOVERY_APPLY,
            f"{flake_reference}#nixosConfigurations",
        ],
    )
    require_success(result, "Could not enumerate this flake's NixOS configurations.")
    value = parse_json(result.stdout, "Invalid configuration discovery result.")
    if not isinstance(value, list):
        raise CheckerError("Configuration discovery did not return a list.")
    candidates = [
        ConfigurationCandidate(str(item.get("name", "")), str(item.get("hostName", "")))
        for item in value
        if isinstance(item, dict)
    ]
    try:
        return select_current_configuration(candidates, hostname)
    except ConfigurationSelectionError as error:
        message, _, diagnostics = str(error).partition("\n")
        raise CheckerError(message, diagnostics) from error


def resolved_path(path: Path) -> str:
    try:
        return str(path.resolve(strict=True))
    except OSError:
        return ""


def generation_name(target: str) -> str:
    if not target:
        return "unknown"
    profiles = Path("/nix/var/nix/profiles")
    try:
        for entry in profiles.glob("system-*-link"):
            if resolved_path(entry) == target:
                return entry.name
    except OSError:
        pass
    return "unknown"


def deriver_for(path: str, *, debug: bool) -> str:
    if not path:
        return ""
    result = run_command(nix_executable(), ["path-info", "--derivation", path])
    if result.succeeded:
        return result.stdout.strip()
    if debug:
        print(f"Could not query deriver for {path}:\n{result.stderr}", file=sys.stderr)
    return ""


def read_repository_settings(repository: Path) -> RepositorySettings:
    path = repository / ".nixos-update-checker.json"
    if not path.exists():
        return RepositorySettings()
    value = read_json_object(path, f"Invalid settings file: {path}")
    try:
        return RepositorySettings.from_json(value)
    except SettingsError as error:
        raise CheckerError(f"Invalid settings file: {path}", str(error)) from error


def input_channel_label(input_name: str, node: JsonObject) -> str:
    original = node.get("original", {})
    reference = str(original.get("ref") or "")
    if reference.startswith("nixos-"):
        return reference.removeprefix("nixos-")
    if reference.startswith("nixpkgs-"):
        return reference.removeprefix("nixpkgs-")
    return reference or input_name


def flake_input_source_channels(
    flake_reference: str, lock_path: Path, lock: JsonObject
) -> dict[str, str]:
    result = run_command(
        nix_executable(),
        [
            "flake",
            "archive",
            "--json",
            "--dry-run",
            "--reference-lock-file",
            str(lock_path),
            flake_reference,
        ],
    )
    require_success(result, "Could not inspect flake input source paths.")
    archive = parse_json(result.stdout, "Invalid flake archive metadata.")
    if not isinstance(archive, dict):
        return {}
    nodes = lock.get("nodes", {})
    root_name = lock.get("root")
    root = nodes.get(root_name, {}) if isinstance(nodes, dict) else {}
    root_inputs = root.get("inputs", {}) if isinstance(root, dict) else {}
    archive_inputs = archive.get("inputs", {})
    if not isinstance(root_inputs, dict) or not isinstance(archive_inputs, dict):
        return {}
    sources: dict[str, str] = {}
    for input_name, archived_input in archive_inputs.items():
        node_name = root_inputs.get(input_name)
        node = nodes.get(node_name, {}) if isinstance(node_name, str) else {}
        original = node.get("original", {}) if isinstance(node, dict) else {}
        locked = node.get("locked", {}) if isinstance(node, dict) else {}
        repository_name = str(original.get("repo") or locked.get("repo") or "")
        reference = str(original.get("ref") or "")
        is_nixpkgs = (
            repository_name == "nixpkgs"
            or reference.startswith("nixos-")
            or "nixpkgs" in str(input_name).lower()
        )
        if not is_nixpkgs:
            continue
        source_path = (
            str(archived_input.get("path") or "") if isinstance(archived_input, dict) else ""
        )
        if source_path:
            sources[source_path] = input_channel_label(str(input_name), node)
    return sources


def annotate_package_channels(packages: list[JsonObject], source_channels: dict[str, str]) -> None:
    ordered_sources = sorted(source_channels.items(), key=lambda item: len(item[0]), reverse=True)
    for package in packages:
        position = str(package.get("position") or "")
        channel = next(
            (label for source, label in ordered_sources if position.startswith(f"{source}/")),
            "",
        )
        if channel:
            package["channel"] = channel


def annotate_manifest_channels(manifest: JsonObject, source_channels: dict[str, str]) -> None:
    for key in (
        "activeOptionPackages",
        "priorityOptionPackages",
        "systemPackages",
        "corePackages",
    ):
        values = manifest.get(key, [])
        if isinstance(values, list):
            annotate_package_channels(values, source_channels)
    users = manifest.get("userPackages", {})
    if isinstance(users, dict):
        for values in users.values():
            if isinstance(values, list):
                annotate_package_channels(values, source_channels)


def configuration_platform(configuration: str, candidate_lock: Path) -> str:
    result = run_command(
        nix_executable(),
        [
            "eval",
            "--raw",
            "--reference-lock-file",
            str(candidate_lock),
            f"{configuration}.pkgs.stdenv.hostPlatform.system",
        ],
    )
    require_success(result, "Could not determine the candidate NixOS platform.")
    return result.stdout.strip()


def annotate_closure_change_channels(
    changes: list[JsonObject],
    source_channels: dict[str, str],
    system: str,
    *,
    debug: bool,
) -> None:
    unresolved_names = sorted(
        {
            str(change.get("name", ""))
            for change in changes
            if change.get("after") and not change.get("channel") and change.get("name")
        }
    )
    if not unresolved_names:
        return
    names = " ".join(nix_quote(name) for name in unresolved_names)
    apply = f"""
pkgs:
let
  names = [ {names} ];
  packagePath = name:
    let result = builtins.tryEval (
      if builtins.hasAttr name pkgs && builtins.isAttrs pkgs.${{name}}
      then pkgs.${{name}}.outPath or null
      else null
    );
    in {{ inherit name; path = if result.success then result.value else null; }};
in builtins.filter (item: item.path != null) (map packagePath names)
"""
    change_paths: dict[str, list[JsonObject]] = {}
    for change in changes:
        after = change.get("after")
        if not isinstance(after, dict):
            continue
        paths = [str(after.get("path") or ""), *map(str, after.get("paths", []))]
        for path in paths:
            if path:
                change_paths.setdefault(path, []).append(change)
    for source, channel in source_channels.items():
        result = run_command(
            nix_executable(),
            ["eval", "--json", "--apply", apply, f"path:{source}#legacyPackages.{system}"],
        )
        if not result.succeeded:
            if debug:
                print(
                    f"Could not resolve package provenance from {channel}:\n{result.stderr}",
                    file=sys.stderr,
                )
            continue
        values = parse_json(result.stdout, f"Invalid package provenance result for {channel}")
        if not isinstance(values, list):
            continue
        for value in values:
            if not isinstance(value, dict):
                continue
            for change in change_paths.get(str(value.get("path") or ""), []):
                change["channel"] = channel


PACKAGE_APPLY = r"""
value:
let
  package = packageValue: {
    name = packageValue.name;
    pname = packageValue.pname or null;
    version = packageValue.version or null;
    description =
      if builtins.isString (packageValue.meta.description or null) then
        packageValue.meta.description
      else
        null;
    position =
      if builtins.isString (packageValue.meta.position or null) then
        packageValue.meta.position
      else
        null;
    path = packageValue.outPath;
  };
  values = if builtins.isList value then value else [ value ];
in
map package values
"""


def evaluate_selected_packages(
    configuration: str,
    options: list[str],
    candidate_lock: Path,
    *,
    candidate: bool,
    debug: bool,
) -> SelectedPackages:
    packages: list[JsonObject] = []
    resolved_options: set[str] = set()
    for option in options:
        arguments = ["eval"]
        if candidate:
            arguments.extend(["--reference-lock-file", str(candidate_lock)])
        arguments.extend(["--json", "--apply", PACKAGE_APPLY, f"{configuration}.config.{option}"])
        result = run_command(nix_executable(), arguments)
        if not result.succeeded:
            if debug:
                print(
                    f"Could not evaluate selected package option {option}:\n{result.stderr}",
                    file=sys.stderr,
                )
            continue
        value = parse_json(result.stdout, f"Invalid package option result for {option}")
        if not isinstance(value, list):
            continue
        resolved_options.add(option)
        for package in value:
            if isinstance(package, dict):
                packages.append({**package, "option": option})
    return SelectedPackages(packages, resolved_options)


def evaluate_manifest(
    configuration: str,
    candidate_lock: Path,
    *,
    candidate: bool,
    include_priority_options: bool = False,
) -> JsonObject:
    evaluator = manifest_evaluator_path()
    try:
        evaluator_source = evaluator.read_text()
    except OSError as error:
        raise CheckerError(
            f"Could not read the bundled package manifest evaluator: {evaluator}", str(error)
        ) from error
    apply = (
        f"configuration: (({evaluator_source}) "
        "{ inherit (configuration) config options; "
        "includePriorityOptionPackages = "
        f"{'true' if include_priority_options else 'false'}; }})"
    )
    arguments = ["eval"]
    if candidate:
        arguments.extend(["--reference-lock-file", str(candidate_lock)])
    arguments.extend(["--json", "--apply", apply, configuration])
    result = run_command(nix_executable(), arguments)
    require_success(
        result,
        f"Could not evaluate the {'candidate' if candidate else 'current'} NixOS package manifest.",
    )
    value = parse_json(result.stdout, "Invalid package manifest JSON.")
    if not isinstance(value, dict):
        raise CheckerError("The evaluated package manifest is not an object.")
    return value


def query_closure(path: str) -> ClosureInformation:
    result = run_command(
        nix_executable(),
        ["path-info", "--json", "--json-format", "1", "--recursive", "--size", path],
    )
    require_success(result, "Could not inspect the realized system closure.")
    value = parse_json(result.stdout, "Invalid system closure JSON.")
    if not isinstance(value, dict):
        raise CheckerError("The system closure query did not return an object.")
    return ClosureInformation.from_path_info(value)


def run_check(options: CheckOptions) -> JsonObject:
    repository = Path(options.repository).expanduser().resolve()
    if not (repository / "flake.nix").exists():
        raise CheckerError(f"Not a flake directory: {repository}")
    lock_path = repository / "flake.lock"
    if not lock_path.exists():
        raise CheckerError("flake.lock is required as the current baseline.")

    hostname = current_hostname()
    flake_reference = f"path:{repository}"
    configuration_name = discover_configuration(flake_reference, hostname)
    configuration = f"{flake_reference}#nixosConfigurations.{nix_quote(configuration_name)}"
    installable = f"{configuration}.config.system.build.toplevel"
    settings = read_repository_settings(repository)
    selected_options = settings.package_options
    real_build = options.build or (options.service and settings.background_build)
    if not real_build:
        build_requester: str | None = None
    elif not options.service:
        build_requester = "interactive"
    elif settings.background_build and not options.build:
        build_requester = "backgroundSetting"
    else:
        build_requester = "serviceArgument"

    running_system = resolved_path(Path("/run/current-system"))
    boot_system = resolved_path(Path("/nix/var/nix/profiles/system"))
    running_deriver = deriver_for(running_system, debug=options.debug)
    boot_deriver = deriver_for(boot_system, debug=options.debug)

    with tempfile.TemporaryDirectory(prefix="nixos-update-checker-") as temporary_directory:
        candidate_lock = Path(temporary_directory) / "flake.lock"

        result = run_command(nix_executable(), ["eval", "--raw", f"{installable}.drvPath"])
        require_success(result, "Could not evaluate the current NixOS toplevel derivation.")
        declared_deriver = result.stdout.strip()

        current_manifest: JsonObject = {}
        if options.inspect_packages and not real_build:
            current_manifest = evaluate_manifest(
                configuration,
                candidate_lock,
                candidate=False,
                include_priority_options=True,
            )

        configuration_state = "unavailable"
        if declared_deriver and running_deriver:
            configuration_state = "applied" if declared_deriver == running_deriver else "differs"
        next_boot_state = "unavailable"
        if declared_deriver and boot_deriver:
            next_boot_state = "matches" if declared_deriver == boot_deriver else "differs"

        lock_before = file_hash(lock_path)
        update = run_command(
            nix_executable(),
            [
                "flake",
                "update",
                "--flake",
                flake_reference,
                "--output-lock-file",
                str(candidate_lock),
            ],
            cwd=repository,
        )
        require_success(update, "Could not resolve updated flake inputs.")
        if lock_before != file_hash(lock_path):
            raise CheckerError("flake.lock changed unexpectedly during a read-only check.")

        current_lock = read_json_object(lock_path, "Invalid current flake.lock.")
        candidate_lock_value = read_json_object(candidate_lock, "Invalid candidate flake.lock.")
        input_changes = compare_inputs(current_lock, candidate_lock_value)
        candidate_source_channels: dict[str, str] = {}
        current_source_channels: dict[str, str] = {}
        if options.inspect_packages or real_build:
            candidate_source_channels = flake_input_source_channels(
                flake_reference, candidate_lock, candidate_lock_value
            )
            if not real_build:
                current_source_channels = flake_input_source_channels(
                    flake_reference, lock_path, current_lock
                )

        package_changes: list[JsonObject] = []
        dependency_changes: list[JsonObject] = []
        resolved_options: set[str] = set()
        package_source = "none"
        baseline_system = ""
        candidate_system = ""
        baseline_closure = ClosureInformation()
        candidate_closure = ClosureInformation()

        if real_build:
            baseline_system = running_system or boot_system
            if not baseline_system:
                raise CheckerError("No running or next-boot system closure is available.")
            build_arguments = [
                "build",
                "--no-link",
                "--print-out-paths",
                "--no-write-lock-file",
                "--reference-lock-file",
                str(candidate_lock),
            ]
            if options.service:
                build_arguments.extend(["--max-jobs", "1", "--cores", "1"])
            build_arguments.append(installable)
            build = run_command(nix_executable(), build_arguments)
            require_success(build, "Could not build the candidate system closure.")
            candidate_paths = build.stdout.split()
            if len(candidate_paths) != 1:
                raise CheckerError("The candidate build did not return exactly one system closure.")
            candidate_system = candidate_paths[0]
            baseline_closure = query_closure(baseline_system)
            candidate_closure = query_closure(candidate_system)
            closure_changes = compare_closures(baseline_closure, candidate_closure)
            if candidate_source_channels:
                annotate_closure_change_channels(
                    closure_changes,
                    candidate_source_channels,
                    configuration_platform(configuration, candidate_lock),
                    debug=options.debug,
                )
            candidate_manifest = evaluate_manifest(
                configuration,
                candidate_lock,
                candidate=True,
                include_priority_options=True,
            )
            candidate_selected = evaluate_selected_packages(
                configuration,
                selected_options,
                candidate_lock,
                candidate=True,
                debug=options.debug,
            )
            annotate_manifest_channels(candidate_manifest, candidate_source_channels)
            annotate_package_channels(candidate_selected.packages, candidate_source_channels)
            resolved_options = candidate_selected.resolved_options
            direct_packages = collect_packages(candidate_manifest, candidate_selected.packages)
            realized_option_packages = [
                package
                for package in candidate_manifest.get("priorityOptionPackages", [])
                if isinstance(package, dict)
                and str(package.get("path", "")) in candidate_closure.paths
            ]
            package_changes, dependency_changes = partition_priority_changes(
                closure_changes,
                [*direct_packages.values(), *realized_option_packages],
            )
            enrich_package_changes(
                [*package_changes, *dependency_changes],
                [*direct_packages.values(), *realized_option_packages],
            )
            package_source = "realizedClosure"
        elif options.inspect_packages:
            candidate_manifest = evaluate_manifest(
                configuration,
                candidate_lock,
                candidate=True,
                include_priority_options=True,
            )
            current_selected = evaluate_selected_packages(
                configuration,
                selected_options,
                candidate_lock,
                candidate=False,
                debug=options.debug,
            )
            candidate_selected = evaluate_selected_packages(
                configuration,
                selected_options,
                candidate_lock,
                candidate=True,
                debug=options.debug,
            )
            annotate_manifest_channels(current_manifest, current_source_channels)
            annotate_manifest_channels(candidate_manifest, candidate_source_channels)
            annotate_package_channels(current_selected.packages, current_source_channels)
            annotate_package_channels(candidate_selected.packages, candidate_source_channels)
            resolved_options = (
                current_selected.resolved_options | candidate_selected.resolved_options
            )
            baseline_system = running_system or boot_system
            if not baseline_system:
                raise CheckerError("No running or next-boot system closure is available.")
            baseline_closure = query_closure(baseline_system)
            current_option_packages = packages_matching_closure(
                (
                    package
                    for package in current_manifest.get("priorityOptionPackages", [])
                    if isinstance(package, dict)
                ),
                baseline_closure,
            )
            candidate_option_packages = packages_matching_closure(
                (
                    package
                    for package in candidate_manifest.get("priorityOptionPackages", [])
                    if isinstance(package, dict)
                ),
                baseline_closure,
            )
            package_changes = compare_packages_to_closure(
                baseline_closure,
                collect_packages(
                    current_manifest,
                    [*current_selected.packages, *current_option_packages],
                ),
                collect_packages(
                    candidate_manifest,
                    [*candidate_selected.packages, *candidate_option_packages],
                ),
            )
            package_source = "evaluatedManifestAgainstRunningClosure"

        if lock_before != file_hash(lock_path):
            raise CheckerError("flake.lock changed unexpectedly during the candidate check.")

    limited = options.service or environment("NIXOS_UPDATE_CHECKER_IN_SCOPE") == "1"
    meaningful_package_changes, primary_store_changes = split_package_changes(package_changes)
    meaningful_dependency_changes, dependency_store_changes = split_package_changes(
        dependency_changes
    )
    store_only_changes = [*primary_store_changes, *dependency_store_changes]
    summary = package_summary(
        [*meaningful_package_changes, *meaningful_dependency_changes, *store_only_changes]
    )
    summary.update(
        {
            "primary": len(meaningful_package_changes),
            "dependencies": len(meaningful_dependency_changes),
        }
    )
    report: JsonObject = {
        "schemaVersion": SCHEMA_VERSION,
        "backendVersion": environment("NIXOS_UPDATE_CHECKER_VERSION", __version__),
        "buildRevision": build_revision(),
        "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "status": "success",
        "repository": str(repository),
        "configuration": configuration_name,
        "resourcePolicy": {
            "limited": limited,
            "mode": "background" if options.service else "interactive",
            "cpuQuota": options.cpu_quota if limited else None,
            "nice": 19 if limited else None,
            "ioClass": "idle" if limited else None,
        },
        "system": {
            "runningPath": running_system or None,
            "nextBootPath": boot_system or None,
            "runningGeneration": generation_name(running_system),
            "nextBootGeneration": generation_name(boot_system),
            "rebootPending": bool(running_system and boot_system and running_system != boot_system),
            "configurationState": configuration_state,
            "nextBootState": next_boot_state,
            "declaredDeriver": declared_deriver or None,
            "runningDeriver": running_deriver or None,
            "nextBootDeriver": boot_deriver or None,
        },
        "inputs": input_changes,
        "packages": {
            "inspected": options.inspect_packages or real_build,
            "source": package_source,
            "changes": meaningful_package_changes,
            "dependencyChanges": meaningful_dependency_changes,
            "storeOnlyChanges": store_only_changes,
            "summary": summary,
            "selectedOptions": selected_options,
            "unresolvedOptions": [
                option
                for option in selected_options
                if options.inspect_packages and option not in resolved_options
            ],
        },
        "build": {
            "performed": real_build,
            "requestedBy": build_requester,
            "baselineSystem": baseline_system or None,
            "candidateSystem": candidate_system or None,
            "baselineClosureBytes": baseline_closure.nar_size if real_build else 0,
            "candidateClosureBytes": candidate_closure.nar_size if real_build else 0,
            "closureSizeDeltaBytes": (
                candidate_closure.nar_size - baseline_closure.nar_size if real_build else 0
            ),
            "addedStorePaths": (
                len(candidate_closure.paths - baseline_closure.paths) if real_build else 0
            ),
            "removedStorePaths": (
                len(baseline_closure.paths - candidate_closure.paths) if real_build else 0
            ),
            "buildLimits": {"maxJobs": 1, "cores": 1} if options.service and real_build else None,
        },
        "updatesAvailable": bool(
            input_changes or meaningful_package_changes or meaningful_dependency_changes
        ),
        "lockFile": {"path": str(lock_path), "modified": False},
    }
    if options.debug:
        print(
            f"Selected current-system configuration: {configuration_name}"
            f"\nRepository: {repository}",
            file=sys.stderr,
        )
    return report


def print_human_report(report: JsonObject) -> None:
    system = report["system"]
    inputs = report["inputs"]
    packages_object = report["packages"]
    packages = packages_object["changes"]
    dependencies = packages_object.get("dependencyChanges", [])
    store_only = packages_object.get("storeOnlyChanges", [])
    build = report["build"]
    print(f"NixOS update check ({report['configuration']})")
    print(f"  repository:    {report['repository']}")
    print(f"  generation:    {system['runningGeneration']}")
    print(f"  configuration: {system['configurationState']}")
    print(f"  reboot pending: {'yes' if system['rebootPending'] else 'no'}")
    print(f"\nInputs: {len(inputs)} change(s)")
    for change in inputs:
        print(f"  {change['name']}: {change['before']['display']} -> {change['after']['display']}")
    source = "realized closure" if build["performed"] else "evaluated manifest"
    print(f"\nPackages: {len(packages)} change(s) ({source})")
    for change in packages:
        print(f"  {change['name']} ({change['kind']})")
    if dependencies:
        print(f"\nDependency changes: {len(dependencies)}")
        for change in dependencies:
            print(f"  {change['name']} ({change['kind']})")
    if store_only:
        print(f"\nStore-only package changes: {len(store_only)}")
        for change in store_only:
            print(f"  {change['name']}")
    if build["performed"]:
        print(f"\nCandidate system: {build['candidateSystem']}")
        print(f"Store paths: +{build['addedStorePaths']} / -{build['removedStorePaths']}")
    print("\nflake.lock unchanged")


def write_report(path: Path, report: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary_name = stream.name
            json.dump(report, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        path.chmod(0o644)
    except OSError as error:
        if temporary_name:
            Path(temporary_name).unlink(missing_ok=True)
        raise CheckerError(f"Could not publish report: {path}", str(error)) from error


def error_report(repository: str, error: CheckerError) -> JsonObject:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "backendVersion": environment("NIXOS_UPDATE_CHECKER_VERSION", __version__),
        "buildRevision": build_revision(),
        "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "status": "error",
        "repository": str(Path(repository).expanduser().resolve()),
        "error": {"message": error.message, "diagnostics": error.diagnostics},
    }


def enter_resource_scope(arguments: list[str], cpu_quota: str) -> NoReturn:
    systemd_run = environment("NIXOS_UPDATE_CHECKER_SYSTEMD_RUN", "systemd-run")
    ionice = environment("NIXOS_UPDATE_CHECKER_IONICE", "ionice")
    nice = environment("NIXOS_UPDATE_CHECKER_NICE", "nice")
    command = [
        systemd_run,
        "--user",
        "--scope",
        "--collect",
        "--quiet",
        "--same-dir",
        "--description=NixOS update check",
        f"--property=CPUQuota={cpu_quota}",
        "--setenv=NIXOS_UPDATE_CHECKER_IN_SCOPE=1",
        f"--setenv=NIXOS_UPDATE_CHECKER_CPU_QUOTA={cpu_quota}",
        ionice,
        "-c",
        "3",
        nice,
        "-n",
        "19",
        sys.executable,
        "-m",
        "nixos_update_checker.checker",
        *arguments,
    ]
    try:
        os.execvp(systemd_run, command)
    except OSError as error:
        raise CheckerError(
            "Could not enter the resource-limited systemd scope.", str(error)
        ) from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check the running flake-based NixOS system for updates"
    )
    parser.add_argument("repository", nargs="?", default=".")
    parser.add_argument(
        "--build",
        action="store_true",
        help="build the candidate closure and report realized closure changes",
    )
    parser.add_argument("--source-only", action="store_true", help="skip manifest inspection")
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--no-limit", action="store_true")
    parser.add_argument(
        "--cpu-quota",
        default=environment("NIXOS_UPDATE_CHECKER_DEFAULT_CPU_QUOTA", "25%"),
    )
    parser.add_argument("--service", action="store_true")
    parser.add_argument("--report", default="/var/lib/nixos-update-checker/report.json")
    parser.add_argument("--version", action="version", version=f"%(prog)s {display_version()}")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    namespace = build_parser().parse_args(arguments)
    if not re.fullmatch(r"[1-9][0-9]*%", namespace.cpu_quota):
        print("--cpu-quota must be a positive percentage such as 25%", file=sys.stderr)
        return 2

    options = CheckOptions(
        repository=namespace.repository,
        cpu_quota=namespace.cpu_quota,
        report_path=namespace.report,
        build=namespace.build,
        inspect_packages=not namespace.source_only,
        json_output=namespace.json_output,
        debug=namespace.debug,
        limit_resources=not namespace.no_limit,
        service=namespace.service,
    )
    if options.service:
        options.json_output = True
        options.limit_resources = False
    if options.limit_resources and environment("NIXOS_UPDATE_CHECKER_IN_SCOPE") != "1":
        enter_resource_scope(arguments, options.cpu_quota)

    try:
        report = run_check(options)
        if options.service:
            write_report(Path(options.report_path), report)
        elif options.json_output:
            json.dump(report, sys.stdout, indent=2)
            print()
        else:
            print_human_report(report)
        return 0
    except CheckerError as error:
        print(f"ERROR: {error.message}", file=sys.stderr)
        if error.diagnostics:
            print(error.diagnostics, file=sys.stderr)
        if options.service:
            try:
                write_report(Path(options.report_path), error_report(options.repository, error))
            except CheckerError as report_error:
                print(f"ERROR: {report_error.message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
