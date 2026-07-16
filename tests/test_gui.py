from __future__ import annotations

from nixos_update_checker.gui import (
    UpdateCheckerWindow,
    group_package_update_rows,
    initial_repository,
    package_set_identity,
    update_detail_lines,
    update_sort_key,
)


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


def test_automatic_and_manual_gui_checks_select_expected_modes() -> None:
    calls: list[tuple[bool, bool]] = []

    class Window:
        def start_check(self, interactive: bool, real_build: bool) -> None:
            calls.append((interactive, real_build))

    UpdateCheckerWindow.start_automatic_check(Window())  # type: ignore[arg-type]
    UpdateCheckerWindow.start_manual_check(Window())  # type: ignore[arg-type]
    assert calls == [(False, False), (True, True)]


def test_package_set_identity_uses_recognizable_runtime_prefixes() -> None:
    assert package_set_identity("python3.13-pyside6") == (
        "python:3.13",
        "Python 3.13 package set",
    )
    assert package_set_identity("lua5_4-lpeg") == (
        "lua:5.4",
        "Lua 5.4 package set",
    )
    assert package_set_identity("firefox") is None


def test_package_set_rows_group_by_set_and_channel_without_losing_count() -> None:
    rows = [
        {
            "type": "nixPkg · unstable",
            "channel": "unstable",
            "name": "python3.13-pyside6",
            "description": "Qt bindings",
            "current": "6.9",
            "available": "6.10",
        },
        {
            "type": "nixPkg · unstable",
            "channel": "unstable",
            "name": "python3.13-rich",
            "description": "Terminal formatting",
            "current": "13.9",
            "available": "14.0",
        },
        {
            "type": "nixPkg · 26.05",
            "channel": "26.05",
            "name": "python3.13-pytest",
            "description": "Test framework",
            "current": "8.3",
            "available": "8.4",
        },
        {
            "type": "nixPkg · unstable",
            "channel": "unstable",
            "name": "firefox",
            "description": "Web browser",
            "current": "140",
            "available": "141",
        },
    ]
    grouped = group_package_update_rows(rows)
    python_group = next(row for row in grouped if row.get("packageChanges"))
    assert python_group["name"] == "Python 3.13 package set"
    assert python_group["updateCount"] == 2
    assert len(python_group["packageChanges"]) == 2
    assert sum(int(row.get("updateCount", 1)) for row in grouped) == len(rows)
    assert any(row["name"] == "python3.13-pytest" for row in grouped)
    assert any(row["name"] == "firefox" for row in grouped)
    assert update_detail_lines(python_group) == [
        "• python3.13-pyside6: 6.9 → 6.10",
        "  Qt bindings",
        "• python3.13-rich: 13.9 → 14.0",
        "  Terminal formatting",
    ]
