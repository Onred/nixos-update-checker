from __future__ import annotations

from nixos_update_checker.gui import initial_repository, update_sort_key


def test_repository_selection_prefers_explicit_then_saved_then_configured_default() -> None:
    assert initial_repository("/cli", "/saved", "/default") == "/cli"
    assert initial_repository(None, "/saved", "/default") == "/saved"
    assert initial_repository(None, "", "/default") == "/default"


def test_updates_sort_flakes_then_channels_then_rebuild() -> None:
    updates = [
        {"type": "nixPkg · unknown", "channel": "unknown", "name": "unknown"},
        {"type": "nixPkg · 25.05", "channel": "25.05", "name": "old"},
        {"type": "rebuild", "name": "Rebuild-only package changes"},
        {"type": "nixPkg · unstable", "channel": "unstable", "name": "edge"},
        {"type": "nixPkg · 25.11", "channel": "25.11", "name": "stable-b"},
        {"type": "flake", "name": "nixpkgs"},
        {"type": "nixPkg · 26.05", "channel": "26.05", "name": "stable-a"},
        {"type": "nixPkg · custom", "channel": "custom", "name": "custom"},
    ]
    updates.sort(key=update_sort_key)
    assert [update["name"] for update in updates] == [
        "nixpkgs",
        "edge",
        "stable-a",
        "stable-b",
        "old",
        "custom",
        "unknown",
        "Rebuild-only package changes",
    ]
