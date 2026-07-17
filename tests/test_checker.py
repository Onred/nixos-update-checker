from __future__ import annotations

import json
from pathlib import Path

import pytest

from nixos_update_checker import checker
from nixos_update_checker.checker import CheckerError, CommandResult
from nixos_update_checker.logic import choose_parallelism


def test_available_cpu_count_respects_the_process_affinity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(checker.os, "sched_getaffinity", lambda _pid: {2, 4, 6})
    assert checker.available_cpu_count() == 3


def test_background_nix_uses_the_direct_local_store(monkeypatch: pytest.MonkeyPatch) -> None:
    call: list[object] = []

    def fake_run(program: str, arguments: list[str], *, cwd: Path | None = None) -> CommandResult:
        call.extend([program, arguments, cwd])
        return CommandResult(0, "", "")

    monkeypatch.setattr(checker, "run_command", fake_run)
    checker.run_nix(["build", ".#system"], background=True)
    assert call[1] == ["--store", "local", "build", ".#system"]


def test_interactive_nix_keeps_the_configured_store(monkeypatch: pytest.MonkeyPatch) -> None:
    arguments_seen: list[str] = []

    def fake_run(program: str, arguments: list[str], *, cwd: Path | None = None) -> CommandResult:
        arguments_seen.extend(arguments)
        return CommandResult(0, "", "")

    monkeypatch.setattr(checker, "run_command", fake_run)
    checker.run_nix(["build", ".#system"], background=False)
    assert arguments_seen == ["build", ".#system"]


def test_only_background_builds_receive_adaptive_job_limits(tmp_path: Path) -> None:
    parallelism = choose_parallelism(16)
    background = checker.build_arguments(
        ".#system", tmp_path / "flake.lock", background=True, parallelism=parallelism
    )
    interactive = checker.build_arguments(
        ".#system", tmp_path / "flake.lock", background=False, parallelism=parallelism
    )
    assert background[background.index("--max-jobs") + 1] == "4"
    assert background[background.index("--cores") + 1] == "4"
    assert "--max-jobs" not in interactive
    assert "--cores" not in interactive
    assert "max-substitution-jobs" not in interactive
    assert "--reference-lock-file" in background
    assert "--no-write-lock-file" in background


def test_closure_query_falls_back_for_older_nix(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []

    def run(args: list[str], *, background: bool) -> CommandResult:
        calls.append(args)
        if "--json-format" in args:
            return CommandResult(1, "", "unknown flag")
        return CommandResult(0, '{"/nix/store/hash-hello-1":{"narSize":12}}', "")

    monkeypatch.setattr(checker, "run_nix", run)
    closure = checker.query_closure("/nix/store/system", background=False)
    assert closure.nar_size == 12
    assert len(calls) == 2
    assert "--json-format" not in calls[1]


def test_configuration_discovery_accepts_single_arbitrarily_named_host(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    arguments_seen: list[str] = []

    def discover(args: list[str], *, background: bool) -> CommandResult:
        arguments_seen.extend(args)
        return CommandResult(0, '[{"name":"my-machine","hostName":"something-else"}]', "")

    monkeypatch.setattr(checker, "run_nix", discover)
    assert (
        checker.discover_configuration("path:/config", "running", background=False) == "my-machine"
    )
    assert "--no-write-lock-file" in arguments_seen


def test_configuration_discovery_reports_invalid_flakes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        checker,
        "run_nix",
        lambda _args, *, background: CommandResult(1, "", "evaluation failed"),
    )
    with pytest.raises(CheckerError, match="enumerate") as raised:
        checker.discover_configuration("path:/config", "running", background=False)
    assert raised.value.diagnostics == "evaluation failed"


def test_report_writes_atomically_and_is_world_readable(tmp_path: Path) -> None:
    destination = tmp_path / "state" / "report.json"
    checker.write_report(destination, {"status": "success", "value": 2})
    assert json.loads(destination.read_text()) == {"status": "success", "value": 2}
    assert destination.stat().st_mode & 0o777 == 0o644
    assert list(destination.parent.glob(".report.json.*")) == []


def test_background_mode_rejects_non_root_before_touching_the_repository(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(checker.os, "geteuid", lambda: 1000)
    with pytest.raises(CheckerError, match="must run as root"):
        checker.run_check(str(tmp_path), background=True)


def test_cli_can_still_emit_json(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        checker,
        "run_check",
        lambda repository, *, background: {
            "status": "success",
            "repository": repository,
            "background": background,
        },
    )
    assert checker.main(["--json", "/config"]) == 0
    assert json.loads(capsys.readouterr().out) == {
        "status": "success",
        "repository": "/config",
        "background": False,
    }


def test_cli_publishes_error_report_for_the_service(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    report = tmp_path / "report.json"

    def fail(_repository: str, *, background: bool) -> dict[str, object]:
        raise CheckerError("failed", "details")

    monkeypatch.setattr(checker, "run_check", fail)
    assert checker.main(["--background", "--report", str(report), "/config"]) == 1
    value = json.loads(report.read_text())
    assert value["status"] == "error"
    assert value["error"] == {"message": "failed", "diagnostics": "details"}
