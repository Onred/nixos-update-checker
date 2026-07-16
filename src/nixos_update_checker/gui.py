from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QDateTime, QProcess, QSettings, Qt, QTimer
from PySide6.QtGui import QAction, QCloseEvent, QColor, QIcon, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QSpinBox,
    QStyle,
    QSystemTrayIcon,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from . import SCHEMA_VERSION, __version__
from .logic import (
    OPTION_PATH,
    JsonObject,
    RepositorySettings,
    SettingsError,
    garbage_collection_arguments,
    interactive_check_arguments,
)


def environment(name: str, fallback: str = "") -> str:
    return os.environ.get(name) or fallback


def canonical_path(path: str) -> str:
    return str(Path(path).expanduser().resolve())


def display_time(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    try:
        return datetime.fromisoformat(value).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    except ValueError:
        return value


def input_revision(value: Any) -> str:
    if not isinstance(value, dict):
        return "—"
    for key in ("display", "revision", "narHash", "url"):
        detail = value.get(key)
        if detail:
            text = str(detail)
            return text[:12] if len(text) > 12 else text
    return "—"


def package_version(value: Any) -> str:
    if not isinstance(value, dict):
        return "unknown"
    return str(value.get("version") or "unknown")


class UpdateCheckerWindow(QMainWindow):
    def __init__(self, repository: str, report_path: str, tray_enabled: bool) -> None:
        super().__init__()
        self.repository = canonical_path(repository)
        self.report_path = Path(report_path)
        self.use_tray = tray_enabled and QSystemTrayIcon.isSystemTrayAvailable()
        self.settings = QSettings("nixos-update-checker", "nixos-update-checker")
        self.report_timer = QTimer(self)
        self.base_icon = self._load_icon()
        self.tray: QSystemTrayIcon | None = None
        self.process: QProcess | None = None
        self.active_job = ""
        self.job_interactive = False
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.last_report: JsonObject = {}
        self.report_mtime_ns = 0
        self.last_notified = ""
        self.pending_settings_temp: Path | None = None
        self.quitting = False
        self.close_hint_shown = False
        self.system_values: dict[str, QLabel] = {}

        self.setWindowIcon(self.base_icon)
        self.setWindowTitle("NixOS Update Checker")
        self.setMinimumSize(800, 600)
        self.resize(980, 720)
        self._build_ui()
        self._build_menus()
        self._build_tray()

        geometry = self.settings.value("windowGeometry")
        if geometry:
            self.restoreGeometry(geometry)
        self.report_timer.setInterval(15_000)
        self.report_timer.timeout.connect(self.load_cached_report)
        self.report_timer.start()
        if not self.load_cached_report():
            QTimer.singleShot(750, lambda: self.start_check(False, False))

    def _load_icon(self) -> QIcon:
        icon_path = environment("NIXOS_UPDATE_CHECKER_ICON")
        if icon_path and Path(icon_path).exists():
            icon = QIcon(icon_path)
            if not icon.isNull():
                return icon
        themed = QIcon.fromTheme("software-update-available")
        if not themed.isNull():
            return themed
        return self.style().standardIcon(QStyle.StandardPixmap.SP_BrowserReload)

    def _status_icon(self, color: QColor | None = None) -> QIcon:
        pixmap = self.base_icon.pixmap(64, 64)
        if color is None or not color.isValid():
            return QIcon(pixmap)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(Qt.GlobalColor.white, 2))
        painter.setBrush(color)
        painter.drawEllipse(42, 42, 19, 19)
        painter.end()
        return QIcon(pixmap)

    def _build_ui(self) -> None:
        central = QWidget(self)
        root = QVBoxLayout(central)
        root.setContentsMargins(18, 18, 18, 14)
        root.setSpacing(12)

        summary = QFrame()
        summary.setObjectName("summaryCard")
        summary_layout = QHBoxLayout(summary)
        self.summary_icon = QLabel()
        self.summary_icon.setPixmap(self.base_icon.pixmap(48, 48))
        self.summary_icon.setFixedSize(56, 56)
        self.summary_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        summary_layout.addWidget(self.summary_icon)
        summary_text = QVBoxLayout()
        self.summary_title = QLabel("Waiting for the first update check")
        self.summary_title.setObjectName("summaryTitle")
        self.summary_detail = QLabel("The cached background report will appear here.")
        self.summary_detail.setWordWrap(True)
        summary_text.addWidget(self.summary_title)
        summary_text.addWidget(self.summary_detail)
        summary_layout.addLayout(summary_text, 1)
        self.last_checked = QLabel("Last checked: never")
        self.last_checked.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        summary_layout.addWidget(self.last_checked)
        root.addWidget(summary)

        target_group = QGroupBox("Current system configuration")
        target_layout = QHBoxLayout(target_group)
        target_layout.addWidget(QLabel("Repository:"))
        self.repository_edit = QLineEdit(self.repository)
        self.repository_edit.editingFinished.connect(self.target_changed)
        target_layout.addWidget(self.repository_edit, 1)
        browse = QToolButton()
        browse.setText("…")
        browse.clicked.connect(self.choose_repository)
        target_layout.addWidget(browse)
        self.settings_button = QPushButton("Settings…")
        self.settings_button.setToolTip(
            "Configure package discovery, background builds, and garbage collection"
        )
        self.settings_button.clicked.connect(self.edit_settings)
        target_layout.addWidget(self.settings_button)
        root.addWidget(target_group)

        actions = QHBoxLayout()
        self.check_button = QPushButton("Check now")
        self.check_button.clicked.connect(lambda: self.start_check(True, False))
        self.build_check_button = QPushButton("Check with build")
        self.build_check_button.setToolTip("Build the updated system closure without applying it")
        self.build_check_button.clicked.connect(lambda: self.start_check(True, True))
        self.update_button = QPushButton("Update inputs")
        self.update_button.clicked.connect(self.confirm_update)
        self.rebuild_button = QPushButton("Rebuild system")
        self.rebuild_button.clicked.connect(self.confirm_rebuild)
        for button in (
            self.check_button,
            self.build_check_button,
            self.update_button,
            self.rebuild_button,
        ):
            actions.addWidget(button)
        actions.addStretch()
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setMaximumWidth(190)
        self.progress.setTextVisible(False)
        self.progress.hide()
        actions.addWidget(self.progress)
        root.addLayout(actions)

        tabs = QTabWidget()
        tabs.addTab(self._build_updates_tab(), "Updates")
        tabs.addTab(self._build_system_tab(), "System")
        tabs.addTab(self._build_activity_tab(), "Activity")
        root.addWidget(tabs, 1)
        self.setCentralWidget(central)
        self.status_message = QLabel("Idle")
        self.statusBar().addWidget(self.status_message, 1)
        self.statusBar().addPermanentWidget(QLabel(str(self.report_path)))
        self.setStyleSheet(
            "QFrame#summaryCard { border: 1px solid palette(mid); border-radius: 8px; "
            "background: palette(alternate-base); } "
            "QLabel#summaryTitle { font-size: 18px; font-weight: 600; } "
            "QGroupBox { font-weight: 600; }"
        )

    def _build_updates_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)
        package_group = QGroupBox("Important package updates")
        package_layout = QVBoxLayout(package_group)
        self.package_table = QTableWidget(0, 4)
        self.package_table.setHorizontalHeaderLabels(["Package", "Change", "Current", "Available"])
        self.package_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.package_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeMode.Stretch
        )
        package_layout.addWidget(self.package_table)
        layout.addWidget(package_group, 2)

        details_group = QGroupBox("Additional details")
        details_layout = QVBoxLayout(details_group)

        self.input_toggle = QToolButton()
        self.input_toggle.setCheckable(True)
        self.input_toggle.setChecked(False)
        self.input_toggle.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.input_toggle.toggled.connect(self.toggle_input_changes)
        details_layout.addWidget(self.input_toggle)
        self.input_table = QTableWidget(0, 3)
        self.input_table.setHorizontalHeaderLabels(["Input", "Current", "Available"])
        self.input_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.input_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.input_table.setVisible(False)
        details_layout.addWidget(self.input_table)

        self.dependency_toggle = QToolButton()
        self.dependency_toggle.setCheckable(True)
        self.dependency_toggle.setChecked(False)
        self.dependency_toggle.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.dependency_toggle.toggled.connect(self.toggle_dependency_changes)
        details_layout.addWidget(self.dependency_toggle)
        self.dependency_table = QTableWidget(0, 4)
        self.dependency_table.setHorizontalHeaderLabels(
            ["Package", "Change", "Current", "Available"]
        )
        self.dependency_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.dependency_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeMode.Stretch
        )
        self.dependency_table.setVisible(False)
        details_layout.addWidget(self.dependency_table)

        self.store_only_toggle = QToolButton()
        self.store_only_toggle.setCheckable(True)
        self.store_only_toggle.setChecked(False)
        self.store_only_toggle.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.store_only_toggle.toggled.connect(self.toggle_store_only_changes)
        details_layout.addWidget(self.store_only_toggle)
        self.store_only_table = QTableWidget(0, 4)
        self.store_only_table.setHorizontalHeaderLabels(
            ["Package", "Change", "Current", "Available"]
        )
        self.store_only_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.store_only_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeMode.Stretch
        )
        self.store_only_table.setVisible(False)
        details_layout.addWidget(self.store_only_table)
        self.set_input_changes([])
        self.set_dependency_changes([])
        self.set_store_only_changes([])
        layout.addWidget(details_group, 1)
        return tab

    def _build_system_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)
        group = QGroupBox("System state")
        form = QFormLayout(group)
        fields = [
            ("runningGeneration", "Running generation"),
            ("nextBootGeneration", "Next-boot generation"),
            ("configurationState", "Working configuration"),
            ("nextBootState", "Next boot"),
            ("rebootPending", "Reboot pending"),
            ("reportSource", "Package report source"),
            ("resourcePolicy", "Check resource policy"),
        ]
        for key, label in fields:
            value = QLabel("Unknown")
            value.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            self.system_values[key] = value
            form.addRow(f"{label}:", value)
        layout.addWidget(group)
        explanation = QLabel(
            "Checks discover the flake configuration matching this machine's hostname. "
            "Package options normally follow enabled NixOS modules; exceptional "
            "package-valued options can be selected in Settings."
        )
        explanation.setWordWrap(True)
        layout.addWidget(explanation)
        layout.addStretch()
        return tab

    def _build_activity_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)
        self.activity = QPlainTextEdit()
        self.activity.setReadOnly(True)
        self.activity.document().setMaximumBlockCount(3000)
        layout.addWidget(self.activity)
        return tab

    def _add_action(self, menu: QMenu, text: str, callback: Any) -> QAction:
        action = QAction(text, self)
        action.triggered.connect(callback)
        menu.addAction(action)
        return action

    def _build_menus(self) -> None:
        file_menu = self.menuBar().addMenu("&File")
        self._add_action(file_menu, "Hide to tray", self.hide)
        file_menu.addSeparator()
        self._add_action(file_menu, "Quit", self.request_quit)
        actions = self.menuBar().addMenu("&Actions")
        self._add_action(actions, "Check now", lambda: self.start_check(True, False))
        self._add_action(actions, "Check with real build", lambda: self.start_check(True, True))
        self._add_action(actions, "Update inputs", self.confirm_update)
        self._add_action(actions, "Rebuild system", self.confirm_rebuild)
        self._add_action(actions, "Settings…", self.edit_settings)
        help_menu = self.menuBar().addMenu("&Help")
        self._add_action(
            help_menu,
            "About",
            lambda: QMessageBox.about(
                self,
                "About NixOS Update Checker",
                f"<b>NixOS Update Checker {__version__}</b><br><br>"
                "Official Qt for Python interface for the currently running NixOS system.",
            ),
        )

    def _build_tray(self) -> None:
        if not self.use_tray:
            return
        self.tray = QSystemTrayIcon(self.base_icon, self)
        menu = QMenu(self)
        self._add_action(menu, "Open NixOS Update Checker", self.show_and_raise)
        menu.addSeparator()
        self._add_action(menu, "Check now", lambda: self.start_check(True, False))
        self._add_action(menu, "Check with real build", lambda: self.start_check(True, True))
        self._add_action(menu, "Update inputs…", self.confirm_update)
        self._add_action(menu, "Rebuild system…", self.confirm_rebuild)
        menu.addSeparator()
        self._add_action(menu, "Quit", self.request_quit)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._tray_activated)
        self.tray.show()

    def _tray_activated(self, reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason in (
            QSystemTrayIcon.ActivationReason.Trigger,
            QSystemTrayIcon.ActivationReason.DoubleClick,
        ):
            self.show_and_raise()

    def target_changed(self) -> None:
        repository = canonical_path(self.repository_edit.text().strip())
        if repository == self.repository:
            return
        self.repository = repository
        self.repository_edit.setText(repository)
        self.report_mtime_ns = 0
        self.last_report = {}
        self.summary_title.setText("Configuration repository changed")
        self.summary_detail.setText("Select Check now to load update information.")
        self.package_table.setRowCount(0)
        self.set_input_changes([])
        self.set_dependency_changes([])
        self.set_store_only_changes([])

    def choose_repository(self) -> None:
        selected = QFileDialog.getExistingDirectory(self, "Choose NixOS flake", self.repository)
        if selected:
            self.repository_edit.setText(selected)
            self.target_changed()

    def validate_target(self, interactive: bool = True) -> bool:
        self.target_changed()
        path = Path(self.repository)
        if (path / "flake.nix").exists() and (path / "flake.lock").exists():
            return True
        detail = f"{self.repository} must contain both flake.nix and flake.lock."
        self.status_message.setText("Invalid current-system configuration")
        self.append_log(detail)
        self.set_tray_state("error")
        if interactive:
            QMessageBox.critical(self, "Invalid current-system configuration", detail)
        return False

    @property
    def settings_path(self) -> Path:
        return Path(self.repository) / ".nixos-update-checker.json"

    def read_repository_settings(self) -> RepositorySettings:
        if not self.settings_path.exists():
            return RepositorySettings()
        try:
            value = json.loads(self.settings_path.read_text())
            if not isinstance(value, dict):
                raise SettingsError("The settings file must contain a JSON object.")
            return RepositorySettings.from_json(value)
        except (OSError, json.JSONDecodeError, SettingsError) as error:
            raise SettingsError(str(error)) from error

    def edit_settings(self) -> None:
        if self.process is not None or not self.validate_target():
            return
        try:
            current = self.read_repository_settings()
        except SettingsError as error:
            QMessageBox.critical(self, "Could not read settings", str(error))
            return

        dialog = QDialog(self)
        dialog.setWindowTitle("NixOS Update Checker settings")
        dialog.resize(620, 520)
        layout = QVBoxLayout(dialog)
        package_label = QLabel(
            "Additional package-valued NixOS options (one per line). Enabled module "
            "options are discovered automatically; use this for exceptional choices "
            "such as hardware.nvidia.package."
        )
        package_label.setWordWrap(True)
        layout.addWidget(package_label)
        package_options = QPlainTextEdit("\n".join(current.package_options))
        package_options.setMaximumHeight(140)
        layout.addWidget(package_options)

        background_build = QCheckBox("Build the candidate system during background checks")
        background_build.setChecked(current.background_build)
        layout.addWidget(background_build)
        build_warning = QLabel(
            "Real builds produce the most accurate closure report, but may run for a long "
            "time and increase Nix store usage. Periodic garbage collection is recommended."
        )
        build_warning.setWordWrap(True)
        build_warning.setStyleSheet("color: palette(mid);")
        layout.addWidget(build_warning)

        garbage_collection = QCheckBox(
            "Garbage collect old generations after a successful system rebuild"
        )
        garbage_collection.setChecked(current.garbage_collection_enabled)
        layout.addWidget(garbage_collection)
        retention_layout = QHBoxLayout()
        retention_layout.addWidget(QLabel("Delete generations older than:"))
        retention_days = QSpinBox()
        retention_days.setRange(1, 3650)
        retention_days.setValue(current.garbage_collection_older_than_days)
        retention_days.setSuffix(" days")
        retention_days.setEnabled(current.garbage_collection_enabled)
        garbage_collection.toggled.connect(retention_days.setEnabled)
        retention_layout.addWidget(retention_days)
        retention_layout.addStretch()
        layout.addLayout(retention_layout)
        gc_warning = QLabel(
            "Garbage collection runs only after Rebuild system succeeds. It removes old "
            "generations and unreferenced store paths, so older rollbacks beyond the "
            "retention period will no longer be available."
        )
        gc_warning.setWordWrap(True)
        gc_warning.setStyleSheet("color: palette(mid);")
        layout.addWidget(gc_warning)
        layout.addStretch()
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return

        options = [
            line.strip() for line in package_options.toPlainText().splitlines() if line.strip()
        ]
        invalid = next(
            (option for option in options if OPTION_PATH.fullmatch(option) is None), None
        )
        if invalid:
            QMessageBox.critical(
                self, "Invalid package option", f"{invalid} is not a NixOS option path."
            )
            return
        updated = RepositorySettings(
            package_options=sorted(set(options)),
            background_build=background_build.isChecked(),
            garbage_collection_enabled=garbage_collection.isChecked(),
            garbage_collection_older_than_days=retention_days.value(),
        )
        data = json.dumps(updated.to_json(), indent=2) + "\n"
        try:
            self.settings_path.write_text(data)
        except OSError:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                prefix="nixos-update-checker-settings-",
                suffix=".json",
                delete=False,
            ) as stream:
                stream.write(data)
                self.pending_settings_temp = Path(stream.name)
            self.start_process(
                "settings",
                environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                [
                    environment("NIXOS_UPDATE_CHECKER_INSTALL", "install"),
                    "-m",
                    "0644",
                    str(self.pending_settings_temp),
                    str(self.settings_path),
                ],
                "Saving settings…",
                True,
            )
            return
        self.append_log(f"Saved settings to {self.settings_path}")
        self.start_check(False, False)

    def load_cached_report(self) -> bool:
        try:
            stat = self.report_path.stat()
        except OSError:
            return False
        if self.report_mtime_ns and stat.st_mtime_ns == self.report_mtime_ns:
            return bool(self.last_report)
        try:
            report = json.loads(self.report_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            self.append_log(f"Could not parse background report: {error}")
            return False
        if not isinstance(report, dict):
            return False
        report_repository = report.get("repository")
        if report_repository and canonical_path(str(report_repository)) != self.repository:
            self.status_message.setText("Background report belongs to a different repository")
            self.report_mtime_ns = stat.st_mtime_ns
            return False
        self.report_mtime_ns = stat.st_mtime_ns
        self.apply_report(report, "background service", bool(self.last_report))
        return True

    def start_check(self, interactive: bool, real_build: bool) -> None:
        if self.process is not None or not self.validate_target(interactive):
            return
        self.start_process(
            "check",
            environment("NIXOS_UPDATE_CHECKER_BACKEND", "check-nixos-updates"),
            interactive_check_arguments(self.repository, real_build=real_build),
            "Building and checking the candidate system…"
            if real_build
            else "Checking for updates…",
            interactive,
        )

    def confirm_update(self) -> None:
        self.show_and_raise()
        if self.process is not None or not self.validate_target():
            return
        lock_path = Path(self.repository) / "flake.lock"
        authorization = not os.access(lock_path, os.W_OK) or not os.access(self.repository, os.W_OK)
        note = "\n\nAdministrator authorization will be requested." if authorization else ""
        answer = QMessageBox.question(
            self,
            "Update flake inputs?",
            f"This will run nix flake update and modify:\n{lock_path}{note}\n\nContinue?",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        nix = environment("NIXOS_UPDATE_CHECKER_NIX", "nix")
        arguments = ["flake", "update", "--flake", f"path:{self.repository}"]
        if authorization:
            self.start_process(
                "update",
                environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                [nix, *arguments],
                "Updating flake inputs…",
                True,
            )
        else:
            self.start_process("update", nix, arguments, "Updating flake inputs…", True)

    def confirm_rebuild(self) -> None:
        self.show_and_raise()
        if self.process is not None or not self.validate_target():
            return
        configuration = str(self.last_report.get("configuration", ""))
        if not configuration:
            QMessageBox.information(
                self,
                "Check required",
                "Run a successful update check before rebuilding so the current NixOS "
                "configuration can be discovered.",
            )
            return
        target = f"path:{self.repository}#{configuration}"
        garbage_collection_note = ""
        try:
            settings = self.read_repository_settings()
            if settings.garbage_collection_enabled:
                garbage_collection_note = (
                    f"\n\nAfter a successful rebuild, generations older than "
                    f"{settings.garbage_collection_older_than_days} days will be garbage collected."
                )
        except SettingsError:
            pass
        answer = QMessageBox.question(
            self,
            "Rebuild NixOS?",
            "This will request administrator authorization and run:\n"
            f"nixos-rebuild switch --flake {target}{garbage_collection_note}\n\nContinue?",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.start_process(
            "rebuild",
            environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
            [
                environment("NIXOS_UPDATE_CHECKER_REBUILD", "nixos-rebuild"),
                "switch",
                "--flake",
                target,
            ],
            "Rebuilding and switching NixOS…",
            True,
        )

    def start_process(
        self,
        job: str,
        program: str,
        arguments: list[str],
        message: str,
        interactive: bool,
    ) -> None:
        self.active_job = job
        self.job_interactive = interactive
        self.stdout.clear()
        self.stderr.clear()
        self.set_busy(True, message)
        self.append_log(f"$ {program} {' '.join(arguments)}")
        process = QProcess(self)
        self.process = process
        process.setWorkingDirectory(self.repository)
        process.readyReadStandardOutput.connect(self._read_stdout)
        process.readyReadStandardError.connect(self._read_stderr)
        process.errorOccurred.connect(self._process_error)
        process.finished.connect(self.process_finished)
        process.start(program, arguments)

    def _read_stdout(self) -> None:
        if self.process is None:
            return
        chunk = bytes(self.process.readAllStandardOutput())
        self.stdout.extend(chunk)
        if self.active_job != "check" and chunk.strip():
            self.activity.appendPlainText(chunk.decode(errors="replace").strip())

    def _read_stderr(self) -> None:
        if self.process is None:
            return
        chunk = bytes(self.process.readAllStandardError())
        self.stderr.extend(chunk)
        if chunk.strip():
            self.activity.appendPlainText(chunk.decode(errors="replace").strip())

    def _process_error(self, error: QProcess.ProcessError) -> None:
        if error != QProcess.ProcessError.FailedToStart or self.process is None:
            return
        detail = self.process.errorString()
        job = self.active_job
        self.process.deleteLater()
        self.process = None
        self.active_job = ""
        self.cleanup_pending_settings()
        self.set_busy(False, f"{job} could not start")
        if self.job_interactive:
            QMessageBox.critical(self, f"Could not start {job}", detail)

    def process_finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        if self.process is None:
            return
        self._read_stdout()
        self._read_stderr()
        job = self.active_job
        interactive = self.job_interactive
        self.process.deleteLater()
        self.process = None
        self.active_job = ""
        if exit_code != 0:
            detail = bytes(self.stderr or self.stdout).decode(errors="replace").strip()
            self.cleanup_pending_settings()
            self.set_busy(False, f"{job} failed")
            self.set_tray_state("error")
            if interactive:
                QMessageBox.critical(self, f"{job} failed", detail[-4000:])
            return
        if job == "check":
            try:
                report = json.loads(self.stdout)
                if not isinstance(report, dict):
                    raise ValueError("Checker report is not an object")
            except (json.JSONDecodeError, ValueError) as error:
                self.set_busy(False, "Checker returned an invalid report")
                self.set_tray_state("error")
                if interactive:
                    QMessageBox.critical(self, "Invalid checker report", str(error))
                return
            self.apply_report(report, "interactive check", True)
            self.set_busy(False, "Check complete")
            return
        if job == "settings":
            self.cleanup_pending_settings()
            self.set_busy(False, "Settings saved")
            QTimer.singleShot(0, lambda: self.start_check(False, False))
            return
        if job == "rebuild":
            try:
                settings = self.read_repository_settings()
            except SettingsError as error:
                self.append_log(f"Could not read garbage-collection settings: {error}")
            else:
                if settings.garbage_collection_enabled:
                    self.start_process(
                        "garbage-collect",
                        environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                        [
                            environment("NIXOS_UPDATE_CHECKER_GC", "nix-collect-garbage"),
                            *garbage_collection_arguments(
                                settings.garbage_collection_older_than_days
                            ),
                        ],
                        "System rebuilt; garbage collecting old generations…",
                        True,
                    )
                    return
        if job == "update":
            label = "Inputs updated"
        elif job == "garbage-collect":
            label = "System rebuild and garbage collection complete"
        else:
            label = "System rebuild complete"
        self.set_busy(False, label)
        QTimer.singleShot(0, lambda: self.start_check(False, False))

    def cleanup_pending_settings(self) -> None:
        if self.pending_settings_temp is not None:
            self.pending_settings_temp.unlink(missing_ok=True)
            self.pending_settings_temp = None

    def set_busy(self, busy: bool, message: str) -> None:
        for widget in (
            self.check_button,
            self.build_check_button,
            self.update_button,
            self.rebuild_button,
            self.settings_button,
            self.repository_edit,
        ):
            widget.setEnabled(not busy)
        self.progress.setVisible(busy)
        self.status_message.setText(message)
        if busy:
            self.set_tray_state("busy")

    def apply_report(self, report: JsonObject, source: str, notify: bool) -> None:
        if report.get("schemaVersion") != SCHEMA_VERSION:
            self.summary_title.setText("Unsupported checker report")
            self.summary_detail.setText("Upgrade the GUI and backend together.")
            self.set_tray_state("error")
            return
        if report.get("status") != "success":
            error = report.get("error", {})
            self.summary_title.setText("Update check failed")
            self.summary_detail.setText(str(error.get("message", "The background checker failed.")))
            self.last_checked.setText(f"Last attempt: {display_time(report.get('generatedAt'))}")
            diagnostics = str(error.get("diagnostics", "")).strip()
            if diagnostics:
                self.activity.appendPlainText(diagnostics)
            self.set_tray_state("error")
            return
        self.last_report = report
        inputs = report.get("inputs", [])
        packages_object = report.get("packages", {})
        reported_packages = packages_object.get("changes", [])
        packages = [change for change in reported_packages if change.get("kind") != "store"]
        reported_dependencies = packages_object.get("dependencyChanges", [])
        dependencies = [change for change in reported_dependencies if change.get("kind") != "store"]
        store_only = [change for change in reported_packages if change.get("kind") == "store"]
        store_only.extend(
            change for change in reported_dependencies if change.get("kind") == "store"
        )
        store_only.extend(packages_object.get("storeOnlyChanges", []))
        system = report.get("system", {})
        build = report.get("build", {})
        updates = bool(report.get("updatesAvailable"))
        rebuild = system.get("configurationState") == "differs"
        if updates:
            if packages:
                self.summary_title.setText(
                    f"{len(packages)} important package "
                    f"{'update' if len(packages) == 1 else 'updates'} available"
                )
            elif dependencies:
                self.summary_title.setText("System dependency updates available")
            else:
                self.summary_title.setText("Flake input updates available")
            suffix = " from a realized system build" if build.get("performed") else ""
            self.summary_detail.setText(
                f"{len(packages)} important packages, {len(dependencies)} dependencies, "
                f"and {len(inputs)} flake inputs{suffix}"
            )
            self.set_tray_state("updates", len(packages) or len(dependencies) or len(inputs))
        elif rebuild:
            self.summary_title.setText("Configuration is ready to rebuild")
            self.summary_detail.setText(
                "The flake is current, but its configuration differs from the running system."
            )
            self.set_tray_state("rebuild")
        else:
            self.summary_title.setText("Your configuration is up to date")
            self.summary_detail.setText(
                "No newer flake inputs or visible package derivations were found."
            )
            self.set_tray_state("current")
        generated = str(report.get("generatedAt", ""))
        self.last_checked.setText(f"Last checked: {display_time(generated)}")
        self.status_message.setText(f"Loaded {source} report")
        self.set_input_changes(inputs)
        self.populate_packages(packages)
        self.set_dependency_changes(dependencies)
        self.set_store_only_changes(store_only)
        self.populate_system(report)
        for option in packages_object.get("unresolvedOptions", []):
            self.append_log(f"Configured package option was not found: {option}")
        if notify and self.tray is not None and generated != self.last_notified:
            self.last_notified = generated
            if updates:
                self.tray.showMessage(
                    "NixOS updates available",
                    self.summary_title.text(),
                    QSystemTrayIcon.MessageIcon.Information,
                    9000,
                )
            elif rebuild:
                self.tray.showMessage(
                    "NixOS rebuild available",
                    self.summary_detail.text(),
                    QSystemTrayIcon.MessageIcon.Information,
                    9000,
                )

    def populate_inputs(self, inputs: list[JsonObject]) -> None:
        self.input_table.setRowCount(len(inputs))
        for row, change in enumerate(inputs):
            self.input_table.setItem(row, 0, QTableWidgetItem(str(change.get("name", ""))))
            self.input_table.setItem(row, 1, QTableWidgetItem(input_revision(change.get("before"))))
            self.input_table.setItem(row, 2, QTableWidgetItem(input_revision(change.get("after"))))

    def set_input_changes(self, inputs: list[JsonObject]) -> None:
        self.populate_inputs(inputs)
        self.input_toggle.setText(f"Flake input changes ({len(inputs)})")
        self.input_toggle.setVisible(bool(inputs))
        self.input_toggle.setChecked(False)
        self.toggle_input_changes(False)

    def toggle_input_changes(self, expanded: bool) -> None:
        self.input_toggle.setArrowType(
            Qt.ArrowType.DownArrow if expanded else Qt.ArrowType.RightArrow
        )
        self.input_table.setVisible(expanded and self.input_table.rowCount() > 0)

    def populate_packages(self, packages: list[JsonObject]) -> None:
        self.populate_package_table(self.package_table, packages)

    def populate_package_table(self, table: QTableWidget, packages: list[JsonObject]) -> None:
        table.setRowCount(len(packages))
        for row, change in enumerate(packages):
            table.setItem(row, 0, QTableWidgetItem(str(change.get("name", ""))))
            table.setItem(row, 1, QTableWidgetItem(str(change.get("kind", ""))))
            table.setItem(row, 2, QTableWidgetItem(package_version(change.get("before"))))
            table.setItem(row, 3, QTableWidgetItem(package_version(change.get("after"))))

    def set_dependency_changes(self, packages: list[JsonObject]) -> None:
        self.populate_package_table(self.dependency_table, packages)
        self.dependency_toggle.setText(f"Dependency changes ({len(packages)})")
        self.dependency_toggle.setVisible(bool(packages))
        self.dependency_toggle.setChecked(False)
        self.toggle_dependency_changes(False)

    def toggle_dependency_changes(self, expanded: bool) -> None:
        self.dependency_toggle.setArrowType(
            Qt.ArrowType.DownArrow if expanded else Qt.ArrowType.RightArrow
        )
        self.dependency_table.setVisible(expanded and self.dependency_table.rowCount() > 0)

    def set_store_only_changes(self, packages: list[JsonObject]) -> None:
        self.populate_package_table(self.store_only_table, packages)
        self.store_only_toggle.setText(f"Store-only changes ({len(packages)})")
        self.store_only_toggle.setVisible(bool(packages))
        self.store_only_toggle.setChecked(False)
        self.toggle_store_only_changes(False)

    def toggle_store_only_changes(self, expanded: bool) -> None:
        self.store_only_toggle.setArrowType(
            Qt.ArrowType.DownArrow if expanded else Qt.ArrowType.RightArrow
        )
        self.store_only_table.setVisible(expanded and self.store_only_table.rowCount() > 0)

    def populate_system(self, report: JsonObject) -> None:
        system = report.get("system", {})
        policy = report.get("resourcePolicy", {})
        packages = report.get("packages", {})
        build = report.get("build", {})
        self.system_values["runningGeneration"].setText(
            str(system.get("runningGeneration", "Unknown"))
        )
        self.system_values["nextBootGeneration"].setText(
            str(system.get("nextBootGeneration", "Unknown"))
        )
        configuration_labels = {
            "applied": "Matches the running system",
            "differs": "Differs from the running system",
            "unavailable": "Unavailable",
        }
        boot_labels = {
            "matches": "Matches the working configuration",
            "differs": "Differs from the working configuration",
            "unavailable": "Unavailable",
        }
        configuration_state = str(system.get("configurationState", "unavailable"))
        boot_state = str(system.get("nextBootState", "unavailable"))
        self.system_values["configurationState"].setText(
            configuration_labels.get(configuration_state, configuration_state)
        )
        self.system_values["nextBootState"].setText(boot_labels.get(boot_state, boot_state))
        self.system_values["rebootPending"].setText("Yes" if system.get("rebootPending") else "No")
        if build.get("performed"):
            report_source = (
                f"Realized closure ({build.get('addedStorePaths', 0)} added, "
                f"{build.get('removedStorePaths', 0)} removed store paths)"
            )
        elif packages.get("source") == "evaluatedManifestAgainstRunningClosure":
            report_source = "Evaluated packages compared with running system"
        else:
            report_source = "Input changes only"
        self.system_values["reportSource"].setText(report_source)
        if policy.get("limited"):
            resource_policy = (
                f"CPU {policy.get('cpuQuota', 'limited')}, nice {policy.get('nice', 19)}, "
                f"{policy.get('ioClass', 'idle')} I/O"
            )
        else:
            resource_policy = "Unrestricted interactive operation"
        self.system_values["resourcePolicy"].setText(resource_policy)

    def set_tray_state(self, state: str, count: int = 0) -> None:
        colors = {
            "busy": QColor("#3498db"),
            "updates": QColor("#f39c12"),
            "rebuild": QColor("#8e44ad"),
            "current": QColor("#27ae60"),
            "error": QColor("#c0392b"),
        }
        icon = self._status_icon(colors.get(state))
        self.summary_icon.setPixmap(icon.pixmap(48, 48))
        if self.tray is None:
            return
        self.tray.setIcon(icon)
        if state == "updates":
            tooltip = f"NixOS Update Checker — {count} updates available"
        elif state == "rebuild":
            tooltip = "NixOS Update Checker — rebuild available"
        elif state == "current":
            tooltip = "NixOS Update Checker — up to date"
        elif state == "error":
            tooltip = "NixOS Update Checker — last check failed"
        else:
            tooltip = "NixOS Update Checker — working…"
        self.tray.setToolTip(tooltip)

    def append_log(self, message: str) -> None:
        self.activity.appendPlainText(
            f"[{QDateTime.currentDateTime().toString('HH:mm:ss')}] {message}"
        )

    def show_and_raise(self) -> None:
        self.show()
        if self.isMinimized():
            self.showNormal()
        self.raise_()
        self.activateWindow()

    def request_quit(self) -> None:
        if self.process is not None:
            self.show_and_raise()
            QMessageBox.information(
                self, "Operation in progress", "Wait for the current operation to finish."
            )
            return
        self.quitting = True
        self.settings.setValue("windowGeometry", self.saveGeometry())
        if self.tray is not None:
            self.tray.hide()
        QApplication.quit()

    def closeEvent(self, event: QCloseEvent) -> None:
        self.settings.setValue("windowGeometry", self.saveGeometry())
        if self.use_tray and not self.quitting:
            self.hide()
            event.ignore()
            if self.tray is not None and not self.close_hint_shown:
                self.close_hint_shown = True
                self.tray.showMessage(
                    "NixOS Update Checker",
                    "The application is still available from the system tray.",
                    QSystemTrayIcon.MessageIcon.Information,
                    5000,
                )
            return
        event.accept()

    def run_self_test(self) -> None:
        report: JsonObject = {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
            "status": "success",
            "repository": self.repository,
            "configuration": "workstation",
            "resourcePolicy": {
                "limited": True,
                "cpuQuota": "25%",
                "nice": 19,
                "ioClass": "idle",
            },
            "system": {
                "runningGeneration": "system-1-link",
                "nextBootGeneration": "system-1-link",
                "configurationState": "applied",
                "nextBootState": "matches",
                "rebootPending": False,
            },
            "inputs": [
                {
                    "name": "nixpkgs",
                    "before": {"display": "11111111"},
                    "after": {"display": "22222222"},
                }
            ],
            "packages": {
                "source": "realizedClosure",
                "changes": [
                    {
                        "name": "example",
                        "kind": "version",
                        "before": {"version": "1.0"},
                        "after": {"version": "2.0"},
                    }
                ],
                "dependencyChanges": [
                    {
                        "name": "library-example",
                        "kind": "version",
                        "before": {"version": "3.0"},
                        "after": {"version": "4.0"},
                    }
                ],
                "storeOnlyChanges": [
                    {
                        "name": "rebuilt-example",
                        "kind": "store",
                        "before": {"version": "1.0"},
                        "after": {"version": "1.0"},
                    }
                ],
                "selectedOptions": [],
                "unresolvedOptions": [],
            },
            "build": {"performed": True, "addedStorePaths": 4, "removedStorePaths": 2},
            "updatesAvailable": True,
        }
        self.apply_report(report, "self-test", False)
        if (
            self.input_table.rowCount() != 1
            or self.package_table.rowCount() != 1
            or self.dependency_table.rowCount() != 1
            or self.store_only_table.rowCount() != 1
            or not self.input_table.isHidden()
            or not self.dependency_table.isHidden()
            or not self.store_only_table.isHidden()
            or self.summary_title.text() != "1 important package update available"
        ):
            raise RuntimeError("GUI report rendering self-test failed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Qt for Python NixOS update checker for the running system"
    )
    parser.add_argument("repository", nargs="?")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--no-tray", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--report",
        default=environment(
            "NIXOS_UPDATE_CHECKER_REPORT", "/var/lib/nixos-update-checker/report.json"
        ),
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: list[str] | None = None) -> int:
    namespace = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    app = QApplication([sys.argv[0]])
    app.setApplicationName("NixOS Update Checker")
    app.setApplicationDisplayName("NixOS Update Checker")
    app.setOrganizationName("nixos-update-checker")
    app.setApplicationVersion(__version__)
    repository = namespace.repository or environment(
        "NIXOS_UPDATE_CHECKER_REPOSITORY", "/etc/nixos"
    )
    window = UpdateCheckerWindow(repository, namespace.report, not namespace.no_tray)
    app.setQuitOnLastWindowClosed(not window.use_tray)
    if namespace.self_test:
        window.run_self_test()
        QTimer.singleShot(0, app.quit)
    elif not namespace.background or not window.use_tray:
        window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
