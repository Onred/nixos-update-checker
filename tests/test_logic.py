from __future__ import annotations

import pytest

from nixos_update_checker.logic import (
    ClosureInformation,
    ConfigurationCandidate,
    ConfigurationSelectionError,
    RepositorySettings,
    SettingsError,
    compare_closures,
    compare_inputs,
    garbage_collection_arguments,
    interactive_check_arguments,
    package_summary,
    parse_store_path,
    select_current_configuration,
    split_package_changes,
)


@pytest.mark.parametrize(
    ("candidates", "hostname", "selected"),
    [
        ([ConfigurationCandidate("desktop-output", "different")], "running", "desktop-output"),
        (
            [
                ConfigurationCandidate("workstation", "nixos"),
                ConfigurationCandidate("server", "server-host"),
            ],
            "nixos",
            "workstation",
        ),
        (
            [
                ConfigurationCandidate("one", "host-one"),
                ConfigurationCandidate("two", "host-two"),
                ConfigurationCandidate("three", "host-three"),
            ],
            "host-two",
            "two",
        ),
        (
            [ConfigurationCandidate("unknown"), ConfigurationCandidate("local", "nixos")],
            "nixos",
            "local",
        ),
        (
            [
                ConfigurationCandidate("laptop.prod", "laptop"),
                ConfigurationCandidate("other", "other"),
            ],
            "laptop",
            "laptop.prod",
        ),
    ],
)
def test_configuration_selection_success(
    candidates: list[ConfigurationCandidate], hostname: str, selected: str
) -> None:
    assert select_current_configuration(candidates, hostname) == selected


@pytest.mark.parametrize(
    ("candidates", "hostname", "message"),
    [
        ([], "nixos", "exports no nixosConfigurations"),
        (
            [ConfigurationCandidate("one", "host-one"), ConfigurationCandidate("two", "host-two")],
            "nixos",
            "No NixOS configuration matches",
        ),
        (
            [ConfigurationCandidate("one", "nixos"), ConfigurationCandidate("two", "nixos")],
            "nixos",
            "More than one NixOS configuration matches",
        ),
    ],
)
def test_configuration_selection_errors(
    candidates: list[ConfigurationCandidate], hostname: str, message: str
) -> None:
    with pytest.raises(ConfigurationSelectionError, match=message):
        select_current_configuration(candidates, hostname)


@pytest.mark.parametrize(
    ("path", "name", "version"),
    [
        ("/nix/store/aaaaaaaa-qtbase-6.8.3", "qtbase", "6.8.3"),
        ("/nix/store/bbbbbbbb-nvidia-x11-570.153.02", "nvidia-x11", "570.153.02"),
        ("/nix/store/cccccccc-linux-6.12.40-modules", "linux", "6.12.40-modules"),
        ("/nix/store/dddddddd-system-path", "system-path", ""),
    ],
)
def test_store_path_parsing(path: str, name: str, version: str) -> None:
    identity = parse_store_path(path)
    assert identity.path == path
    assert identity.name == name
    assert identity.version == version


def test_legacy_settings_defaults() -> None:
    settings = RepositorySettings.from_json({"schemaVersion": 1, "packageOptions": []})
    assert not settings.background_build
    assert not settings.garbage_collection_enabled
    assert settings.garbage_collection_older_than_days == 30


def test_settings_round_trip() -> None:
    expected = RepositorySettings(
        package_options=["hardware.nvidia.package", "hardware.graphics.package"],
        background_build=True,
        garbage_collection_enabled=True,
        garbage_collection_older_than_days=45,
    )
    actual = RepositorySettings.from_json(expected.to_json())
    assert actual == RepositorySettings(
        package_options=["hardware.graphics.package", "hardware.nvidia.package"],
        background_build=True,
        garbage_collection_enabled=True,
        garbage_collection_older_than_days=45,
    )


@pytest.mark.parametrize("days", [0, 3651, 1.5, True])
def test_settings_reject_invalid_retention(days: object) -> None:
    with pytest.raises(SettingsError, match="between 1 and 3650"):
        RepositorySettings.from_json(
            {
                "schemaVersion": 1,
                "packageOptions": [],
                "garbageCollection": {"enabled": True, "olderThanDays": days},
            }
        )


def test_interactive_checks_are_unrestricted() -> None:
    assert interactive_check_arguments("/etc/nixos", real_build=False) == [
        "--json",
        "--no-limit",
        "/etc/nixos",
    ]
    assert interactive_check_arguments("/etc/nixos", real_build=True) == [
        "--json",
        "--no-limit",
        "--build",
        "/etc/nixos",
    ]


def test_garbage_collection_retention_argument() -> None:
    assert garbage_collection_arguments(30) == ["--delete-older-than", "30d"]


def test_input_comparison_detects_changed_and_added_nodes() -> None:
    current = {"nodes": {"nixpkgs": {"locked": {"rev": "old"}}}}
    candidate = {
        "nodes": {
            "nixpkgs": {"locked": {"rev": "new"}},
            "extra": {"locked": {"narHash": "sha256-new"}},
        }
    }
    changes = compare_inputs(current, candidate)
    assert [change["name"] for change in changes] == ["extra", "nixpkgs"]


def test_realized_closure_comparison_uses_actual_store_paths() -> None:
    current = ClosureInformation.from_path_info(
        {
            "/nix/store/aaaaaaaa-example-1.0": {"narSize": 10},
            "/nix/store/bbbbbbbb-stable-2.0": {"narSize": 20},
        }
    )
    candidate = ClosureInformation.from_path_info(
        {
            "/nix/store/cccccccc-example-2.0": {"narSize": 15},
            "/nix/store/bbbbbbbb-stable-2.0": {"narSize": 20},
            "/nix/store/dddddddd-added-1.0": {"narSize": 30},
        }
    )
    changes = compare_closures(current, candidate)
    assert [(change["name"], change["kind"]) for change in changes] == [
        ("added", "added"),
        ("example", "version"),
    ]
    assert candidate.nar_size == 65


def test_store_only_package_changes_do_not_count_as_updates() -> None:
    changes = [
        {"name": "updated", "kind": "version"},
        {"name": "rebuilt", "kind": "store"},
    ]
    meaningful, store_only = split_package_changes(changes)
    assert [change["name"] for change in meaningful] == ["updated"]
    assert [change["name"] for change in store_only] == ["rebuilt"]
    assert package_summary(changes) == {
        "total": 1,
        "versions": 1,
        "additions": 0,
        "removals": 0,
        "storeOnly": 1,
    }
