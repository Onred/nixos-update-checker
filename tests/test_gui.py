from __future__ import annotations

from PySide6.QtGui import QColor

from nixos_update_checker.gui import (
    color_contrast_ratio,
    initial_repository,
    readable_muted_color,
    report_rows,
    update_detail_lines,
)


def test_repository_selection_prefers_explicit_then_saved_then_packaged_default() -> None:
    assert initial_repository("/cli", "/saved", "/default") == "/cli"
    assert initial_repository(None, "/saved", "/default") == "/saved"
    assert initial_repository(None, "", "/default") == "/default"


def test_report_rows_are_flakes_then_packages_then_one_rebuild_summary() -> None:
    report = {
        "inputs": [{"name": "nixpkgs", "before": {"display": "old"}, "after": {"display": "new"}}],
        "packages": {
            "changes": [
                {
                    "name": "zlib",
                    "kind": "version",
                    "before": {"version": "1"},
                    "after": {"version": "2"},
                },
                {
                    "name": "removed",
                    "kind": "removed",
                    "before": {"version": "1"},
                    "after": None,
                },
            ],
            "storeOnlyChanges": [
                {"name": "glibc", "kind": "store"},
                {"name": "openssl", "kind": "store"},
            ],
        },
    }
    rows = report_rows(report)
    assert [(row["type"], row["name"]) for row in rows] == [
        ("Flake", "nixpkgs"),
        ("Package", "removed"),
        ("Package", "zlib"),
        ("Rebuild", "Rebuilt dependencies"),
    ]
    assert rows[-1]["available"] == "2 changes"


def test_information_shows_old_versions_and_rebuild_members() -> None:
    package = {
        "type": "Package",
        "name": "firefox",
        "current": "140",
        "available": "141",
    }
    assert update_detail_lines(package) == ["firefox", "• 140 → 141"]
    rebuild = {
        "type": "Rebuild",
        "changes": [
            {
                "name": "glibc",
                "before": {"version": "2.40"},
                "after": {"version": "2.40"},
            }
        ],
    }
    assert update_detail_lines(rebuild) == [
        "Rebuild-only dependency changes",
        "",
        "glibc",
        "• 2.40 → 2.40",
    ]


def test_muted_text_remains_readable_in_light_and_dark_palettes() -> None:
    for text, background in (
        (QColor("#202020"), QColor("#ffffff")),
        (QColor("#f0f0f0"), QColor("#202020")),
    ):
        muted = readable_muted_color(text, background)
        assert color_contrast_ratio(muted, background) >= 4.5
