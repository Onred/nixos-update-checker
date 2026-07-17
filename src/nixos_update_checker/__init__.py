"""NixOS Update Checker application package."""

from __future__ import annotations

import os

__version__ = "2.0.0"
SCHEMA_VERSION = 2


def build_revision() -> str | None:
    """Return the flake revision embedded by the Nix package, when available."""
    revision = os.environ.get("NIXOS_UPDATE_CHECKER_REVISION", "").strip()
    return revision if revision and revision != "unknown" else None


def display_version() -> str:
    """Return a human-readable version that identifies the packaged checkout."""
    revision = build_revision()
    return f"{__version__} ({revision})" if revision else __version__
