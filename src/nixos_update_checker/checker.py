from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION, __version__, build_revision, display_version
from .logic import (
    BuildParallelism,
    ClosureInformation,
    ConfigurationCandidate,
    ConfigurationSelectionError,
    JsonObject,
    choose_parallelism,
    compare_closures,
    compare_inputs,
    input_details,
    nix_quote,
    package_summary,
    select_current_configuration,
    split_package_changes,
)

APPLIED_LOCK_SCHEMA = 1


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


def environment(name: str, fallback: str = "") -> str:
    return os.environ.get(name) or fallback


def nix_executable() -> str:
    return environment("NIXOS_UPDATE_CHECKER_NIX", "nix")


def applied_lock_path() -> Path:
    return Path(
        environment(
            "NIXOS_UPDATE_CHECKER_APPLIED_LOCK",
            "/var/lib/nixos-update-checker/applied-flake-lock.json",
        )
    )


def available_cpu_count() -> int:
    """Return CPUs available to this process, respecting a systemd CPU affinity mask."""
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except (AttributeError, OSError):
        return max(1, os.cpu_count() or 1)


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


def run_nix(arguments: list[str], *, background: bool) -> CommandResult:
    prefix = ["--store", "local"] if background else []
    return run_command(nix_executable(), [*prefix, *arguments])


def require_success(result: CommandResult, message: str) -> None:
    if not result.succeeded:
        raise CheckerError(message, result.stderr.strip() or result.stdout.strip())


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
        raise CheckerError("Could not determine the running hostname.", str(error)) from error
    if not hostname:
        raise CheckerError("The running hostname is empty.")
    return hostname


def running_nixpkgs_revision() -> str:
    executable = environment(
        "NIXOS_UPDATE_CHECKER_NIXOS_VERSION",
        "/run/current-system/sw/bin/nixos-version",
    )
    result = run_command(executable, ["--json"])
    if not result.succeeded:
        return ""
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return ""
    return str(value.get("nixpkgsRevision", "")) if isinstance(value, dict) else ""


def root_input_node(lock: JsonObject, input_name: str) -> tuple[str, JsonObject] | None:
    nodes = lock.get("nodes", {})
    root_name = lock.get("root")
    if not isinstance(nodes, dict) or not isinstance(root_name, str):
        return None
    root = nodes.get(root_name, {})
    inputs = root.get("inputs", {}) if isinstance(root, dict) else {}
    node_name = inputs.get(input_name) if isinstance(inputs, dict) else None
    if not isinstance(node_name, str):
        return None
    node = nodes.get(node_name, {})
    return (node_name, node) if isinstance(node, dict) else None


def include_running_nixpkgs_change(
    changes: list[JsonObject], candidate_lock: JsonObject, revision: str
) -> list[JsonObject]:
    """Keep the primary nixpkgs update visible before an applied snapshot exists."""
    candidate = root_input_node(candidate_lock, "nixpkgs")
    if not revision or candidate is None:
        return changes
    node_name, node = candidate
    locked = node.get("locked", {})
    candidate_revision = str(locked.get("rev", "")) if isinstance(locked, dict) else ""
    if not candidate_revision or candidate_revision == revision:
        return changes
    before = {
        "revision": revision,
        "narHash": None,
        "url": None,
        "lastModified": None,
        "display": revision[:8],
    }
    replacement = {"name": node_name, "before": before, "after": input_details(node)}
    result = [change for change in changes if change.get("name") != node_name]
    result.append(replacement)
    return sorted(result, key=lambda change: str(change.get("name", "")))


def write_applied_lock_snapshot(repository: Path, lock: JsonObject, destination: Path) -> None:
    write_json_file(
        destination,
        {
            "schemaVersion": APPLIED_LOCK_SCHEMA,
            "repository": str(repository),
            "recordedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
            "lock": lock,
        },
    )


def record_applied_lock(repository_value: str, destination: Path) -> None:
    repository = Path(repository_value).expanduser().resolve()
    lock_path = repository / "flake.lock"
    lock = read_json_object(lock_path, f"Invalid flake lock: {lock_path}")
    write_applied_lock_snapshot(repository, lock, destination)


def read_applied_lock(repository: Path, path: Path) -> JsonObject | None:
    if not path.is_file():
        return None
    try:
        snapshot = read_json_object(path, f"Invalid applied lock snapshot: {path}")
    except CheckerError:
        return None
    lock = snapshot.get("lock")
    if (
        snapshot.get("schemaVersion") != APPLIED_LOCK_SCHEMA
        or snapshot.get("repository") != str(repository)
        or not isinstance(lock, dict)
    ):
        return None
    return lock


DISCOVERY_APPLY = r"""
configs:
map
  (name:
    let result = builtins.tryEval configs.${name}.config.networking.hostName;
    in { inherit name; hostName = if result.success then result.value else ""; })
  (builtins.attrNames configs)
"""


def discover_configuration(flake_reference: str, hostname: str, *, background: bool) -> str:
    result = run_nix(
        [
            "eval",
            "--json",
            "--no-write-lock-file",
            "--apply",
            DISCOVERY_APPLY,
            f"{flake_reference}#nixosConfigurations",
        ],
        background=background,
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
    try:
        for entry in Path("/nix/var/nix/profiles").glob("system-*-link"):
            if resolved_path(entry) == target:
                return entry.name
    except OSError:
        pass
    return "unknown"


def deriver_for(path: str, *, background: bool) -> str:
    if not path:
        return ""
    result = run_nix(["path-info", "--derivation", path], background=background)
    return result.stdout.strip() if result.succeeded else ""


def query_closure(path: str, *, background: bool) -> ClosureInformation:
    common = ["path-info", "--json", "--recursive", "--size", path]
    result = run_nix([*common[:2], "--json-format", "1", *common[2:]], background=background)
    if not result.succeeded:
        # Nix releases before --json-format used format 1 as their only JSON shape.
        result = run_nix(common, background=background)
    require_success(result, f"Could not inspect the realized closure: {path}")
    value = parse_json(result.stdout, "Invalid closure information returned by Nix.")
    if not isinstance(value, dict):
        raise CheckerError("The closure query did not return an object.")
    return ClosureInformation.from_path_info(value)


def build_arguments(
    installable: str,
    candidate_lock: Path,
    *,
    background: bool,
    parallelism: BuildParallelism,
) -> list[str]:
    arguments = [
        "build",
        "--no-link",
        "--print-out-paths",
        "--no-write-lock-file",
        "--reference-lock-file",
        str(candidate_lock),
    ]
    if background:
        arguments[0:0] = [
            "--option",
            "max-substitution-jobs",
            str(parallelism.substitution_jobs),
        ]
        arguments.extend(
            ["--max-jobs", str(parallelism.max_jobs), "--cores", str(parallelism.cores_per_job)]
        )
    arguments.append(installable)
    return arguments


def current_cgroup() -> str:
    try:
        for line in Path("/proc/self/cgroup").read_text().splitlines():
            if line.startswith("0::"):
                return line[3:]
    except OSError:
        pass
    return ""


def run_check(repository_value: str, *, background: bool) -> JsonObject:
    repository = Path(repository_value).expanduser().resolve()
    if background and os.geteuid() != 0:
        raise CheckerError("Background builds must run as root so Nix can use the local store.")
    if not (repository / "flake.nix").is_file():
        raise CheckerError(f"Not a flake directory: {repository}")
    lock_path = repository / "flake.lock"
    if not lock_path.is_file():
        raise CheckerError("flake.lock is required as the current baseline.")

    lock_before = file_hash(lock_path)
    flake_reference = f"path:{repository}"
    configuration_name = discover_configuration(
        flake_reference, current_hostname(), background=background
    )
    quoted_name = nix_quote(configuration_name)
    configuration = f"{flake_reference}#nixosConfigurations.{quoted_name}"
    installable = f"{configuration}.config.system.build.toplevel"

    running_system = resolved_path(Path("/run/current-system"))
    boot_system = resolved_path(Path("/nix/var/nix/profiles/system"))
    baseline_system = running_system or boot_system
    if not baseline_system:
        raise CheckerError("No running or next-boot NixOS system closure is available.")

    declared = run_nix(
        ["eval", "--raw", "--no-write-lock-file", f"{installable}.drvPath"],
        background=background,
    )
    require_success(declared, "Could not evaluate the configured NixOS system.")
    if lock_before != file_hash(lock_path):
        raise CheckerError("flake.lock changed unexpectedly during current-system evaluation.")
    declared_deriver = declared.stdout.strip()
    running_deriver = deriver_for(running_system, background=background)
    configuration_state = "unavailable"
    if declared_deriver and running_deriver:
        configuration_state = "applied" if declared_deriver == running_deriver else "differs"

    parallelism = choose_parallelism(available_cpu_count())
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="nixos-update-checker-") as temporary_directory:
        candidate_lock = Path(temporary_directory) / "flake.lock"
        update = run_nix(
            [
                "flake",
                "update",
                "--flake",
                flake_reference,
                "--output-lock-file",
                str(candidate_lock),
            ],
            background=background,
        )
        require_success(update, "Could not resolve updated flake inputs.")
        if lock_before != file_hash(lock_path):
            raise CheckerError("flake.lock changed unexpectedly during a read-only check.")

        current_lock = read_json_object(lock_path, "Invalid current flake.lock.")
        candidate_lock_value = read_json_object(candidate_lock, "Invalid candidate flake.lock.")
        snapshot_path = applied_lock_path()
        applied_lock = read_applied_lock(repository, snapshot_path)
        baseline_source = "appliedSnapshot" if applied_lock is not None else "workingLock"
        if configuration_state == "applied":
            applied_lock = current_lock
            baseline_source = "currentConfiguration"
            with contextlib.suppress(CheckerError):
                write_applied_lock_snapshot(repository, current_lock, snapshot_path)
        input_baseline = applied_lock or current_lock
        input_changes = compare_inputs(input_baseline, candidate_lock_value)
        running_revision = running_nixpkgs_revision()
        if applied_lock is None:
            input_changes = include_running_nixpkgs_change(
                input_changes, candidate_lock_value, running_revision
            )

        build = run_nix(
            build_arguments(
                installable,
                candidate_lock,
                background=background,
                parallelism=parallelism,
            ),
            background=background,
        )
        require_success(build, "Could not build the candidate NixOS system.")
        candidate_paths = build.stdout.split()
        if len(candidate_paths) != 1:
            raise CheckerError("The candidate build did not return exactly one system closure.")
        candidate_system = candidate_paths[0]

        current_closure = query_closure(baseline_system, background=background)
        candidate_closure = query_closure(candidate_system, background=background)

    if lock_before != file_hash(lock_path):
        raise CheckerError("flake.lock changed unexpectedly during the candidate build.")

    all_package_changes = compare_closures(current_closure, candidate_closure)
    package_changes, store_only_changes = split_package_changes(all_package_changes)
    elapsed = round(time.monotonic() - started, 3)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "backendVersion": environment("NIXOS_UPDATE_CHECKER_VERSION", __version__),
        "buildRevision": build_revision(),
        "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "status": "success",
        "repository": str(repository),
        "configuration": configuration_name,
        "inputs": input_changes,
        "inputBaseline": {
            "source": baseline_source,
            "path": str(snapshot_path) if baseline_source == "appliedSnapshot" else str(lock_path),
            "runningNixpkgsRevision": running_revision or None,
        },
        "packages": {
            "changes": package_changes,
            "storeOnlyChanges": store_only_changes,
            "summary": package_summary(all_package_changes),
        },
        "system": {
            "runningSystem": running_system or None,
            "bootSystem": boot_system or None,
            "runningGeneration": generation_name(running_system),
            "configurationState": configuration_state,
            "rebootPending": bool(running_system and boot_system and running_system != boot_system),
        },
        "build": {
            "performed": True,
            "background": background,
            "candidateSystem": candidate_system,
            "elapsedSeconds": elapsed,
            "storeMode": "local" if background else "auto",
            "cgroup": current_cgroup(),
            "parallelism": asdict(parallelism) if background else None,
            "baselineClosureBytes": current_closure.nar_size,
            "candidateClosureBytes": candidate_closure.nar_size,
            "closureSizeDeltaBytes": candidate_closure.nar_size - current_closure.nar_size,
            "addedStorePaths": len(candidate_closure.paths - current_closure.paths),
            "removedStorePaths": len(current_closure.paths - candidate_closure.paths),
        },
        "updatesAvailable": bool(input_changes or package_changes),
        "rebuildRequired": bool(store_only_changes),
        "lockFile": {"path": str(lock_path), "modified": False},
    }


def write_json_file(path: Path, value: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        path.chmod(0o644)
    except OSError as error:
        if temporary_name:
            Path(temporary_name).unlink(missing_ok=True)
        raise CheckerError(f"Could not publish report: {path}", str(error)) from error


def write_report(path: Path, report: JsonObject) -> None:
    write_json_file(path, report)


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


def print_human_report(report: JsonObject) -> None:
    inputs = report.get("inputs", [])
    packages = report.get("packages", {})
    changes = packages.get("changes", []) if isinstance(packages, dict) else []
    store_only = packages.get("storeOnlyChanges", []) if isinstance(packages, dict) else []
    build = report.get("build", {})
    print(f"NixOS update check: {report.get('configuration', 'unknown')}")
    print(f"Flake inputs: {len(inputs)}")
    print(f"Package updates: {len(changes)}")
    print(f"Rebuild-only changes: {len(store_only)}")
    if isinstance(build, dict):
        print(f"Build time: {build.get('elapsedSeconds', 0)} seconds")
    print("flake.lock unchanged")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build and compare a candidate NixOS system")
    parser.add_argument("repository", nargs="?", default=".")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--record-applied-lock", action="store_true")
    parser.add_argument("--applied-lock", type=Path, default=applied_lock_path())
    parser.add_argument("--report", type=Path)
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--version", action="version", version=f"%(prog)s {display_version()}")
    return parser


def main(argv: list[str] | None = None) -> int:
    namespace = build_parser().parse_args(argv)
    try:
        if namespace.record_applied_lock:
            record_applied_lock(namespace.repository, namespace.applied_lock)
            return 0
        report = run_check(namespace.repository, background=namespace.background)
        if namespace.report:
            write_report(namespace.report, report)
        if namespace.json_output:
            json.dump(report, sys.stdout, indent=2)
            print()
        elif not namespace.report:
            print_human_report(report)
        return 0
    except CheckerError as error:
        print(f"ERROR: {error.message}", file=sys.stderr)
        if error.diagnostics:
            print(error.diagnostics, file=sys.stderr)
        if namespace.report:
            try:
                write_report(namespace.report, error_report(namespace.repository, error))
            except CheckerError as report_error:
                print(f"ERROR: {report_error.message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
