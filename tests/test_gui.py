from __future__ import annotations

from PySide6.QtGui import QColor

from nixos_update_checker.gui import (
    UpdateCheckerWindow,
    color_contrast_ratio,
    group_package_update_rows,
    hover_border_edges,
    initial_repository,
    package_set_identity,
    package_type_label,
    readable_muted_color,
    update_detail_lines,
    update_sort_key,
)


def test_repository_selection_prefers_explicit_then_saved_then_configured_default() -> None:
    assert initial_repository("/cli", "/saved", "/default") == "/cli"
    assert initial_repository(None, "/saved", "/default") == "/saved"
    assert initial_repository(None, "", "/default") == "/default"


def test_updates_sort_flakes_then_channels_then_rebuild() -> None:
    updates = [
        {"type": "nixPkg", "channel": "unknown", "name": "unknown"},
        {"type": "nixPkg 25.05", "channel": "25.05", "name": "old"},
        {"type": "rebuild", "name": "Rebuild-only package changes"},
        {"type": "nixPkg unstable", "channel": "unstable", "name": "edge"},
        {"type": "nixPkg 25.11", "channel": "25.11", "name": "stable-b"},
        {"type": "flake", "name": "nixpkgs"},
        {"type": "nixPkg 26.05", "channel": "26.05", "name": "stable-a"},
        {"type": "nixPkg custom", "channel": "custom", "name": "custom"},
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
    UpdateCheckerWindow.start_post_rebuild_check(Window())  # type: ignore[arg-type]
    assert calls == [(False, False), (True, True), (False, True)]


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
            "type": "nixPkg unstable",
            "channel": "unstable",
            "name": "python3.13-pyside6",
            "description": "Qt bindings",
            "current": "6.9",
            "available": "6.10",
        },
        {
            "type": "nixPkg unstable",
            "channel": "unstable",
            "name": "python3.13-rich",
            "description": "Terminal formatting",
            "current": "13.9",
            "available": "14.0",
        },
        {
            "type": "nixPkg 26.05",
            "channel": "26.05",
            "name": "python3.13-pytest",
            "description": "Test framework",
            "current": "8.3",
            "available": "8.4",
        },
        {
            "type": "nixPkg unstable",
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
        "python3.13-pyside6",
        "• 6.9 → 6.10",
        "• Qt bindings",
        "",
        "python3.13-rich",
        "• 13.9 → 14.0",
        "• Terminal formatting",
    ]


def test_explicit_kde_package_set_groups_names_without_a_shared_prefix() -> None:
    rows = [
        {
            "type": "nixPkg",
            "channel": "unknown",
            "packageSet": "kdePackages",
            "name": name,
            "description": "",
            "current": "1",
            "available": "2",
        }
        for name in ("dolphin", "kwin", "okular")
    ]
    assert package_type_label("unknown") == "nixPkg"
    assert package_type_label("unstable") == "nixPkg unstable"
    grouped = group_package_update_rows(rows)
    assert len(grouped) == 1
    assert grouped[0]["name"] == "kdePackages"
    assert grouped[0]["available"] == "3 updates"


def test_individual_package_information_uses_unbulleted_name_and_bulleted_details() -> None:
    assert update_detail_lines(
        {
            "type": "nixPkg",
            "name": "firefox",
            "current": "140",
            "available": "141",
            "description": "Web browser",
        }
    ) == ["firefox", "• 140 → 141", "• Web browser"]


def test_muted_description_color_comes_from_palette_and_remains_readable() -> None:
    text = QColor("#000000")
    background = QColor("#ffffff")
    muted = readable_muted_color(text, background)
    assert muted != text
    assert muted != background
    assert color_contrast_ratio(muted, background) >= 4.5
    assert muted.red() >= 100


def test_hover_border_edges_form_one_outer_row_outline() -> None:
    assert hover_border_edges(0, 3) == {"top", "bottom", "left"}
    assert hover_border_edges(1, 3) == {"top", "bottom"}
    assert hover_border_edges(2, 3) == {"top", "bottom", "right"}
