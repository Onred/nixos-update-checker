from __future__ import annotations

import json
from pathlib import Path

import pytest

from nixos_update_checker import checker


def test_discovery_selects_output_name_that_differs_from_hostname(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    result = checker.CommandResult(
        0,
        json.dumps(
            [
                {"name": "workstation", "hostName": "nixos"},
                {"name": "server", "hostName": "server-host"},
            ]
        ),
        "",
    )
    monkeypatch.setattr(checker, "run_command", lambda *_args, **_kwargs: result)
    assert checker.discover_configuration("path:/config", "nixos") == "workstation"


def test_service_report_is_atomically_replaced(tmp_path: Path) -> None:
    path = tmp_path / "state" / "report.json"
    checker.write_report(path, {"schemaVersion": 1, "status": "success"})
    assert json.loads(path.read_text()) == {"schemaVersion": 1, "status": "success"}
    assert path.stat().st_mode & 0o777 == 0o644
    assert list(path.parent.iterdir()) == [path]


def test_cli_accepts_json_and_build_together(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        checker,
        "run_check",
        lambda options: {
            "schemaVersion": 1,
            "status": "success",
            "build": {"performed": options.build},
        },
    )
    assert checker.main(["--json", "--build", "--no-limit", "/config"]) == 0
    assert json.loads(capsys.readouterr().out)["build"]["performed"] is True


@pytest.mark.parametrize("candidate", [False, True])
def test_manifest_is_evaluated_from_the_selected_configuration_without_module_import(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, candidate: bool
) -> None:
    evaluator = tmp_path / "manifest.nix"
    evaluator.write_text("{ config, options }: { inherit config options; }\n")
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_MANIFEST", str(evaluator))
    calls: list[list[str]] = []

    def run_command(
        _program: str, arguments: list[str], **_kwargs: object
    ) -> checker.CommandResult:
        calls.append(arguments)
        return checker.CommandResult(0, '{"toplevelDeriver":"/nix/store/example.drv"}', "")

    monkeypatch.setattr(checker, "run_command", run_command)
    candidate_lock = tmp_path / "flake.lock"
    configuration = 'path:/config#nixosConfigurations."workstation"'

    assert checker.evaluate_manifest(configuration, candidate_lock, candidate=candidate) == {
        "toplevelDeriver": "/nix/store/example.drv"
    }

    arguments = calls[0]
    assert arguments[-1] == configuration
    assert "--apply" in arguments
    apply = arguments[arguments.index("--apply") + 1]
    assert "{ config, options }:" in apply
    assert "inherit (configuration) config options" in apply
    assert "import" not in apply
    assert "programs.nixos-update-checker.manifest" not in " ".join(arguments)
    assert ("--reference-lock-file" in arguments) is candidate
