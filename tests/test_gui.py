from __future__ import annotations

from nixos_update_checker.gui import initial_repository


def test_repository_selection_prefers_explicit_then_saved_then_configured_default() -> None:
    assert initial_repository("/cli", "/saved", "/default") == "/cli"
    assert initial_repository(None, "/saved", "/default") == "/saved"
    assert initial_repository(None, "", "/default") == "/default"
