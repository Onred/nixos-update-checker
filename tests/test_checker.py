from __future__ import annotations

import json
from pathlib import Path

import pytest

from nixos_update_checker import checker, display_version


def test_display_version_includes_packaged_flake_revision(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_REVISION", "72ffd10-dirty")
    assert display_version() == "1.0.0 (72ffd10-dirty)"


def test_display_version_omits_unknown_revision(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_REVISION", "unknown")
    assert display_version() == "1.0.0"


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


def test_flake_input_sources_are_labeled_by_nixpkgs_branch(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    archive = {
        "inputs": {
            "stable": {"path": "/nix/store/stable-source"},
            "unstable": {"path": "/nix/store/unstable-source"},
        }
    }
    monkeypatch.setattr(
        checker,
        "run_command",
        lambda *_args, **_kwargs: checker.CommandResult(0, json.dumps(archive), ""),
    )
    lock = {
        "root": "root",
        "nodes": {
            "root": {"inputs": {"stable": "stable-node", "unstable": "unstable-node"}},
            "stable-node": {"original": {"ref": "nixos-26.05"}},
            "unstable-node": {"original": {"ref": "nixos-unstable"}},
        },
    }
    sources = checker.flake_input_source_channels("path:/config", tmp_path / "lock", lock)
    assert sources == {
        "/nix/store/stable-source": "26.05",
        "/nix/store/unstable-source": "unstable",
    }

    packages = [
        {"position": "/nix/store/stable-source/pkgs/example.nix:1"},
        {"position": "/nix/store/unstable-source/pkgs/example.nix:1"},
        {"position": "/nix/store/other-source/package.nix:1"},
    ]
    checker.annotate_package_channels(packages, sources)
    assert [package.get("channel") for package in packages] == [
        "26.05",
        "unstable",
        None,
    ]


def test_closure_package_channel_requires_exact_output_match(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_CACHE", str(tmp_path))
    calls: list[list[str]] = []

    def run_command(
        _program: str, arguments: list[str], **_kwargs: object
    ) -> checker.CommandResult:
        calls.append(arguments)
        if arguments[0] == "search":
            return checker.CommandResult(
                0,
                json.dumps(
                    {
                        "legacyPackages.x86_64-linux.hello": {
                            "pname": "hello",
                            "version": "2.12",
                        }
                    }
                ),
                "",
            )
        assert arguments[0] == "eval"
        return checker.CommandResult(
            0,
            json.dumps(
                [
                    "/nix/store/aaaaaaaa-hello-2.12",
                    "/nix/store/unrelated-other-1.0",
                ]
            ),
            "",
        )

    monkeypatch.setattr(checker, "run_command", run_command)
    changes = [
        {
            "name": "hello",
            "after": {
                "path": "/nix/store/aaaaaaaa-hello-2.12",
                "paths": ["/nix/store/aaaaaaaa-hello-2.12"],
            },
        },
        {"name": "other", "after": {"path": "/nix/store/bbbbbbbb-other-1.0"}},
    ]
    checker.annotate_closure_change_channels(
        changes,
        {"/nix/store/nixpkgs-source": "unstable"},
        "x86_64-linux",
        debug=False,
    )
    assert changes[0]["channel"] == "unstable"
    assert "channel" not in changes[1]
    assert [arguments[0] for arguments in calls] == ["search", "eval"]

    calls.clear()
    second_changes = [
        {
            "name": "hello",
            "after": {"path": "/nix/store/aaaaaaaa-hello-2.12"},
        }
    ]
    checker.annotate_closure_change_channels(
        second_changes,
        {"/nix/store/nixpkgs-source": "unstable"},
        "x86_64-linux",
        debug=False,
    )
    assert second_changes[0]["channel"] == "unstable"
    assert calls == []


def test_closure_package_channel_finds_nested_package_set_in_one_batch(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_CACHE", str(tmp_path))
    calls: list[list[str]] = []

    def run_command(
        _program: str, arguments: list[str], **_kwargs: object
    ) -> checker.CommandResult:
        calls.append(arguments)
        if arguments[0] == "search":
            assert "pyside6" in arguments[-1]
            assert "rich" in arguments[-1]
            return checker.CommandResult(
                0,
                json.dumps(
                    {
                        "legacyPackages.x86_64-linux.python313Packages.pyside6": {},
                        "legacyPackages.x86_64-linux.python313Packages.rich": {},
                    }
                ),
                "",
            )
        apply = arguments[arguments.index("--apply") + 1]
        assert "pkgs.python313Packages.pyside6" in apply
        assert "pkgs.python313Packages.rich" in apply
        return checker.CommandResult(
            0,
            json.dumps(
                [
                    "/nix/store/aaaaaaaa-python3.13-pyside6-6.9.0",
                    "/nix/store/bbbbbbbb-python3.13-rich-14.0.0",
                ]
            ),
            "",
        )

    monkeypatch.setattr(checker, "run_command", run_command)
    changes = [
        {
            "name": "python3.13-pyside6",
            "after": {"path": "/nix/store/aaaaaaaa-python3.13-pyside6-6.9.0"},
        },
        {
            "name": "python3.13-rich",
            "after": {"path": "/nix/store/bbbbbbbb-python3.13-rich-14.0.0"},
        },
    ]
    checker.annotate_closure_change_channels(
        changes,
        {"/nix/store/nixpkgs-source": "26.05"},
        "x86_64-linux",
        debug=False,
    )
    assert [change["channel"] for change in changes] == ["26.05", "26.05"]
    assert [arguments[0] for arguments in calls] == ["search", "eval"]


def test_nix_search_regex_escapes_dots_but_not_hyphens() -> None:
    assert checker.nix_search_regex_literal("python3.13-pyside6") == (
        r"python3\.13-pyside6"
    )


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
