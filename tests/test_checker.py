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
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    values = [
        {"name": "hello", "path": "/nix/store/aaaaaaaa-hello-2.12"},
        {"name": "other", "path": "/nix/store/unrelated-other-1.0"},
    ]
    monkeypatch.setattr(
        checker,
        "run_command",
        lambda *_args, **_kwargs: checker.CommandResult(0, json.dumps(values), ""),
    )
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


def test_package_set_annotation_requires_an_exact_candidate_output_match(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_CACHE", str(tmp_path))
    values = [
        {
            "packageSet": "kdePackages",
            "attribute": "dolphin",
            "paths": ["/nix/store/aaaaaaaa-dolphin-26.05"],
            "description": "KDE file manager",
            "position": "/nix/store/nixpkgs-source/kde/dolphin.nix:1",
        },
        {
            "packageSet": "kdePackages",
            "attribute": "okular",
            "paths": ["/nix/store/unrelated-okular-26.05"],
            "description": "Document viewer",
        },
    ]
    calls: list[list[str]] = []

    def run_command(
        _program: str, arguments: list[str], **_kwargs: object
    ) -> checker.CommandResult:
        calls.append(arguments)
        return checker.CommandResult(0, json.dumps(values), "")

    monkeypatch.setattr(checker, "run_command", run_command)
    changes = [
        {"name": "dolphin", "after": {"path": "/nix/store/aaaaaaaa-dolphin-26.05"}},
        {"name": "okular", "after": {"path": "/nix/store/bbbbbbbb-okular-26.05"}},
    ]
    candidate_lock = tmp_path / "flake.lock"
    checker.annotate_package_sets(
        changes,
        'path:/config#nixosConfigurations."workstation"',
        candidate_lock,
        ("kdePackages",),
        {"/nix/store/nixpkgs-source": "unstable"},
        "/nix/store/candidate-system.drv",
        False,
        debug=False,
    )
    assert changes[0]["packageSet"] == "kdePackages"
    assert changes[0]["description"] == "KDE file manager"
    assert changes[0]["channel"] == "unstable"
    assert "packageSet" not in changes[1]
    assert calls[0][-1].endswith('nixosConfigurations."workstation"')
    assert calls[0][calls[0].index("--reference-lock-file") + 1] == str(candidate_lock)
    apply = calls[0][calls[0].index("--apply") + 1]
    assert "builtins.hasAttr attribute packageSet.value" in apply
    assert '"dolphin"' in apply


def test_full_package_set_results_are_cached_and_reused(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_CACHE", str(tmp_path))
    values = [
        {
            "packageSet": "kdePackages",
            "attribute": "dolphin",
            "paths": ["/nix/store/aaaaaaaa-dolphin-26.05"],
            "description": None,
            "position": None,
        }
    ]
    calls = 0

    def run_command(*_args: object, **_kwargs: object) -> checker.CommandResult:
        nonlocal calls
        calls += 1
        return checker.CommandResult(0, json.dumps(values), "")

    monkeypatch.setattr(checker, "run_command", run_command)
    arguments = (
        'path:/config#nixosConfigurations."workstation"',
        tmp_path / "flake.lock",
        ("kdePackages",),
        {},
        "/nix/store/candidate-system.drv",
    )
    first = [{"name": "dolphin", "after": {"path": values[0]["paths"][0]}}]
    checker.annotate_package_sets(first, *arguments, full=True, debug=False)
    assert first[0]["packageSet"] == "kdePackages"
    assert calls == 1

    second = [{"name": "dolphin", "after": {"path": values[0]["paths"][0]}}]
    checker.annotate_package_sets(second, *arguments, full=False, debug=False)
    assert second[0]["packageSet"] == "kdePackages"
    assert calls == 1
    assert checker.package_set_cache_path(arguments[-1]).is_file()


def test_selective_package_set_names_include_ecosystem_aliases() -> None:
    aliases = checker.package_set_candidate_names(
        [
            {"name": "python3.13-pyside6"},
            {"name": "ghc9.10-aeson"},
            {"name": "r-ggplot2"},
        ]
    )
    assert {"pyside6", "aeson", "ggplot2"} <= aliases


def test_package_set_cache_prunes_old_configuration_generations(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("NIXOS_UPDATE_CHECKER_CACHE", str(tmp_path))
    for index in range(checker.PACKAGE_SET_CACHE_LIMIT + 1):
        identity = f"/nix/store/system-{index}.drv"
        checker.write_package_set_cache(
            identity,
            ("kdePackages",),
            [{"packageSet": "kdePackages", "paths": [f"/nix/store/package-{index}"]}],
            debug=False,
        )
    assert len(list(checker.package_set_cache_directory().glob("*.json.gz"))) == 3
    latest_identity = f"/nix/store/system-{checker.PACKAGE_SET_CACHE_LIMIT}.drv"
    assert checker.read_package_set_cache(latest_identity, ("kdePackages",)) is not None
    assert checker.read_package_set_cache(latest_identity, ("gnome",)) is None


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
