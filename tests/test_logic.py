from __future__ import annotations

import pytest

from nixos_update_checker.logic import (
    ClosureInformation,
    ConfigurationCandidate,
    ConfigurationSelectionError,
    choose_parallelism,
    compare_closures,
    compare_inputs,
    garbage_collection_arguments,
    package_summary,
    parse_store_path,
    select_current_configuration,
    split_package_changes,
)


def path_info(*paths: tuple[str, int]) -> ClosureInformation:
    return ClosureInformation.from_path_info(
        {f"/nix/store/{size:032d}-{name}": {"narSize": size} for name, size in paths}
    )


def test_single_configuration_does_not_require_a_hostname_convention() -> None:
    assert (
        select_current_configuration([ConfigurationCandidate("desktop")], "unrelated") == "desktop"
    )


def test_multiple_configurations_select_the_running_hostname() -> None:
    candidates = [
        ConfigurationCandidate("workstation", "nixos"),
        ConfigurationCandidate("server", "server"),
    ]
    assert select_current_configuration(candidates, "nixos") == "workstation"


@pytest.mark.parametrize(
    ("candidates", "message"),
    [
        ([], "exports no nixosConfigurations"),
        ([ConfigurationCandidate("a", "other"), ConfigurationCandidate("b", "server")], "No NixOS"),
        (
            [ConfigurationCandidate("a", "host"), ConfigurationCandidate("b", "host")],
            "More than one",
        ),
    ],
)
def test_ambiguous_configuration_cases_are_actionable(
    candidates: list[ConfigurationCandidate], message: str
) -> None:
    with pytest.raises(ConfigurationSelectionError, match=message):
        select_current_configuration(candidates, "host")


@pytest.mark.parametrize(
    ("logical_cpus", "expected"),
    [
        (None, (1, 1, 1)),
        (1, (1, 1, 1)),
        (2, (2, 1, 2)),
        (4, (4, 2, 2)),
        (8, (8, 2, 4)),
        (16, (16, 4, 4)),
        (32, (32, 5, 6)),
        (128, (32, 5, 6)),
    ],
)
def test_parallelism_adapts_and_is_bounded(
    logical_cpus: int | None, expected: tuple[int, int, int]
) -> None:
    selected = choose_parallelism(logical_cpus)
    assert (selected.worker_budget, selected.max_jobs, selected.cores_per_job) == expected
    assert 1 <= selected.max_jobs * selected.cores_per_job <= selected.worker_budget
    assert 1 <= selected.substitution_jobs <= 4


@pytest.mark.parametrize(
    ("path", "name", "version"),
    [
        ("/nix/store/hash-firefox-141.0", "firefox", "141.0"),
        ("/nix/store/hash-nvidia-x11-610.1", "nvidia-x11", "610.1"),
        ("/nix/store/hash-steam-1.0.0.85-shell-env", "steam", "1.0.0.85-shell-env"),
        ("/nix/store/hash-unversioned", "unversioned", ""),
    ],
)
def test_store_path_identity(path: str, name: str, version: str) -> None:
    assert parse_store_path(path).name == name
    assert parse_store_path(path).version == version


def test_closure_diff_separates_updates_from_rebuild_only_paths() -> None:
    current = path_info(("firefox-140", 100), ("glibc-2.40", 20), ("removed-1", 2))
    candidate = path_info(("firefox-141", 110), ("glibc-2.40", 21), ("added-1", 3))
    changes = compare_closures(current, candidate)
    meaningful, store_only = split_package_changes(changes)
    assert {(item["name"], item["kind"]) for item in meaningful} == {
        ("added", "added"),
        ("firefox", "version"),
        ("removed", "removed"),
    }
    assert [(item["name"], item["kind"]) for item in store_only] == [("glibc", "store")]
    assert package_summary(changes) == {
        "total": 3,
        "versions": 1,
        "additions": 1,
        "removals": 1,
        "storeOnly": 1,
    }


def test_flake_input_diff_uses_locked_identity() -> None:
    before = {"nodes": {"nixpkgs": {"locked": {"rev": "old"}}, "root": {}}}
    after = {"nodes": {"nixpkgs": {"locked": {"rev": "new"}}, "root": {}}}
    assert compare_inputs(before, after) == [
        {
            "name": "nixpkgs",
            "before": {
                "revision": "old",
                "narHash": None,
                "url": None,
                "lastModified": None,
                "display": "old",
            },
            "after": {
                "revision": "new",
                "narHash": None,
                "url": None,
                "lastModified": None,
                "display": "new",
            },
        }
    ]


def test_garbage_collection_retention_is_safely_bounded() -> None:
    assert garbage_collection_arguments(30) == ["--delete-older-than", "30d"]
    assert garbage_collection_arguments(0)[1] == "1d"
    assert garbage_collection_arguments(9999)[1] == "3650d"
