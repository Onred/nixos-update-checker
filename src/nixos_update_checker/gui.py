from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QModelIndex, QProcess, QRect, QSettings, QSize, Qt, QTimer
from PySide6.QtGui import QCloseEvent, QColor, QIcon, QPainter, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QSpinBox,
    QSplitter,
    QStyle,
    QStyledItemDelegate,
    QStyleOptionViewItem,
    QSystemTrayIcon,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from . import SCHEMA_VERSION, display_version
from .logic import JsonObject, garbage_collection_arguments

ROW_ROLE = int(Qt.ItemDataRole.UserRole)
SECTION_ROLE = ROW_ROLE + 1


def environment(name: str, fallback: str = "") -> str:
    return os.environ.get(name) or fallback


def canonical_path(path: str) -> str:
    return str(Path(path).expanduser().resolve()) if path else ""


def initial_repository(explicit: str | None, saved: str, configured_default: str) -> str:
    return explicit or saved or configured_default


def color_contrast_ratio(first: QColor, second: QColor) -> float:
    def luminance(color: QColor) -> float:
        channels = []
        for value in (color.redF(), color.greenF(), color.blueF()):
            channels.append(value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4)
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

    lighter, darker = sorted((luminance(first), luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def readable_muted_color(text: QColor, background: QColor) -> QColor:
    for weight in (0.68, 0.76, 0.84, 0.92):
        candidate = QColor(
            round(text.red() * weight + background.red() * (1 - weight)),
            round(text.green() * weight + background.green() * (1 - weight)),
            round(text.blue() * weight + background.blue() * (1 - weight)),
        )
        if color_contrast_ratio(candidate, background) >= 4.5:
            return candidate
    return text


def display_time(value: Any) -> str:
    try:
        return datetime.fromisoformat(str(value)).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return str(value or "unknown")


def update_sort_key(row: JsonObject) -> tuple[int, str]:
    order = {"Flake": 0, "Package": 1, "Rebuild": 2}
    return order.get(str(row.get("type", "")), 9), str(row.get("name", "")).casefold()


def report_rows(report: JsonObject) -> list[JsonObject]:
    rows: list[JsonObject] = []
    inputs = report.get("inputs", [])
    if isinstance(inputs, list):
        for change in inputs:
            if not isinstance(change, dict):
                continue
            before_value = change.get("before")
            after_value = change.get("after")
            before = before_value if isinstance(before_value, dict) else {}
            after = after_value if isinstance(after_value, dict) else {}
            rows.append(
                {
                    "type": "Flake",
                    "name": str(change.get("name", "")),
                    "current": str(before.get("display", "missing")),
                    "available": str(after.get("display", "missing")),
                    "change": change,
                }
            )

    packages = report.get("packages", {})
    if not isinstance(packages, dict):
        packages = {}
    changes = packages.get("changes", [])
    if isinstance(changes, list):
        for change in changes:
            if not isinstance(change, dict):
                continue
            package_after = change.get("after") if isinstance(change.get("after"), dict) else None
            package_before = (
                change.get("before") if isinstance(change.get("before"), dict) else None
            )
            rows.append(
                {
                    "type": "Package",
                    "name": str(change.get("name", "")),
                    "current": str((package_before or {}).get("version", "not installed")),
                    "available": (
                        "removed"
                        if package_after is None
                        else str(package_after.get("version", "unversioned"))
                    ),
                    "change": change,
                }
            )

    store_values = packages.get("storeOnlyChanges", [])
    store_only = (
        [change for change in store_values if isinstance(change, dict)]
        if isinstance(store_values, list)
        else []
    )
    if store_only:
        rows.append(
            {
                "type": "Rebuild",
                "name": "Rebuilt dependencies",
                "current": "",
                "available": f"{len(store_only)} changes",
                "changes": store_only,
            }
        )
    rows.sort(key=update_sort_key)
    return rows


def update_detail_lines(row: JsonObject) -> list[str]:
    if row.get("type") == "Rebuild":
        lines = ["Rebuild-only dependency changes", ""]
        for change in row.get("changes", []):
            if not isinstance(change, dict):
                continue
            before_value = change.get("before")
            after_value = change.get("after")
            before = before_value if isinstance(before_value, dict) else {}
            after = after_value if isinstance(after_value, dict) else {}
            lines.extend(
                [
                    str(change.get("name", "")),
                    "• "
                    f"{before.get('version', 'unversioned')} → "
                    f"{after.get('version', 'unversioned')}",
                    "",
                ]
            )
        return lines[:-1]

    lines = [str(row.get("name", ""))]
    current = str(row.get("current", ""))
    available = str(row.get("available", ""))
    if current or available:
        lines.append(f"• {current or 'missing'} → {available or 'missing'}")
    change = row.get("change")
    if isinstance(change, dict):
        for side_name in ("before", "after"):
            side = change.get(side_name)
            if isinstance(side, dict) and side.get("url"):
                lines.append(f"• {side_name.title()}: {side['url']}")
            if isinstance(side, dict):
                paths = side.get("paths", [])
                if isinstance(paths, list):
                    lines.extend(f"• {side_name.title()} path: {path}" for path in paths)
    return lines


class UpdateItemDelegate(QStyledItemDelegate):
    """Paint update rows through the active desktop style without table chrome."""

    def sizeHint(self, option: QStyleOptionViewItem, index: QModelIndex) -> QSize:
        return QSize(option.rect.width(), 34 if index.data(SECTION_ROLE) else 54)

    def paint(
        self,
        painter: QPainter,
        option: QStyleOptionViewItem,
        index: QModelIndex,
    ) -> None:
        section = index.data(SECTION_ROLE)
        if section:
            painter.save()
            font = option.font
            font.setBold(True)
            painter.setFont(font)
            color = readable_muted_color(
                option.palette.color(QPalette.ColorRole.Text),
                option.palette.color(QPalette.ColorRole.Base),
            )
            painter.setPen(color)
            painter.drawText(
                option.rect.adjusted(12, 4, -12, 0),
                Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                str(section),
            )
            painter.restore()
            return

        row = index.data(ROW_ROLE)
        if not isinstance(row, dict):
            super().paint(painter, option, index)
            return

        styled = QStyleOptionViewItem(option)
        self.initStyleOption(styled, index)
        styled.text = ""
        style = styled.widget.style() if styled.widget is not None else QApplication.style()
        style.drawControl(QStyle.ControlElement.CE_ItemViewItem, styled, painter, styled.widget)

        selected = bool(styled.state & QStyle.StateFlag.State_Selected)
        role = QPalette.ColorRole.HighlightedText if selected else QPalette.ColorRole.Text
        painter.save()
        painter.setPen(styled.palette.color(role))
        content = styled.rect.adjusted(14, 7, -14, -7)
        available_width = min(260, max(150, content.width() // 3))
        name_rect = QRect(
            content.left(), content.top(), content.width() - available_width - 18, content.height()
        )
        available_rect = QRect(
            content.right() - available_width,
            content.top(),
            available_width,
            content.height(),
        )
        name_font = styled.font
        name_font.setBold(True)
        painter.setFont(name_font)
        name = painter.fontMetrics().elidedText(
            str(row.get("name", "")), Qt.TextElideMode.ElideRight, name_rect.width()
        )
        painter.drawText(
            name_rect,
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
            name,
        )
        painter.setFont(styled.font)
        available = painter.fontMetrics().elidedText(
            str(row.get("available", "")),
            Qt.TextElideMode.ElideLeft,
            available_rect.width(),
        )
        painter.drawText(
            available_rect,
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
            available,
        )
        painter.restore()


class SettingsDialog(QDialog):
    def __init__(self, parent: QWidget, repository: str, settings: QSettings) -> None:
        super().__init__(parent)
        self.setWindowTitle("Settings")
        self.resize(560, 230)
        layout = QVBoxLayout(self)
        form = QFormLayout()
        repository_row = QWidget()
        repository_layout = QHBoxLayout(repository_row)
        repository_layout.setContentsMargins(0, 0, 0, 0)
        self.repository = QLineEdit(repository)
        browse = QPushButton("Browse…")
        browse.clicked.connect(self.browse)
        repository_layout.addWidget(self.repository, 1)
        repository_layout.addWidget(browse)
        form.addRow("NixOS flake", repository_row)
        self.garbage_collection = QCheckBox("Garbage collect after a successful rebuild")
        self.garbage_collection.setChecked(
            settings.value("garbageCollectionEnabled", False, type=bool)
        )
        form.addRow("Cleanup", self.garbage_collection)
        self.retention = QSpinBox()
        self.retention.setRange(1, 3650)
        self.retention.setSuffix(" days")
        self.retention.setValue(settings.value("garbageCollectionDays", 30, type=int))
        form.addRow("Keep generations", self.retention)
        layout.addLayout(form)
        note = QLabel(
            "Background checks use thermally limited candidate builds, which can increase "
            "Nix store usage. Configured cleanup runs only after an applied rebuild. "
            "Refresh and Rebuild are unrestricted."
        )
        note.setWordWrap(True)
        layout.addWidget(note)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def browse(self) -> None:
        selected = QFileDialog.getExistingDirectory(
            self, "Choose NixOS flake", self.repository.text()
        )
        if selected:
            self.repository.setText(selected)


class UpdateCheckerWindow(QMainWindow):
    def __init__(self, repository: str, report_path: str, tray_enabled: bool) -> None:
        super().__init__()
        self.repository = canonical_path(repository)
        self.report_path = Path(report_path)
        self.tray_enabled = tray_enabled and QSystemTrayIcon.isSystemTrayAvailable()
        self.settings = QSettings("nixos-update-checker", "nixos-update-checker")
        self.last_report: JsonObject = {}
        self.report_mtime_ns = 0
        self.process: QProcess | None = None
        self.active_job = ""
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.pending_configuration = ""
        self.quit_requested = False
        self.rendered_update_count = 0
        self.setWindowTitle("NixOS Update Checker")
        self.resize(1000, 720)
        self._build_ui()
        self._build_tray()
        self.report_timer = QTimer(self)
        self.report_timer.timeout.connect(self.load_cached_report)
        self.report_timer.start(5000)
        self.load_cached_report()

    def _build_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(18, 16, 18, 14)
        layout.setSpacing(8)

        summaries = QHBoxLayout()
        self.package_summary = self._summary_widget("Packages")
        self.flake_summary = self._summary_widget("Flakes")
        self.rebuild_summary = self._summary_widget("Rebuild-only")
        summaries.addWidget(self.package_summary)
        summaries.addWidget(self.flake_summary)
        summaries.addWidget(self.rebuild_summary)
        summaries.addStretch()
        layout.addLayout(summaries)

        self.status = QLabel("No report loaded")
        layout.addWidget(self.status)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(3)
        self.progress.hide()
        layout.addWidget(self.progress)

        splitter = QSplitter(Qt.Orientation.Vertical)
        self.updates = QListWidget()
        self.updates.setItemDelegate(UpdateItemDelegate(self.updates))
        self.updates.setMouseTracking(True)
        self.updates.setSpacing(2)
        self.updates.currentItemChanged.connect(self.update_information)
        splitter.addWidget(self.updates)

        tabs = QTabWidget()
        self.information = QPlainTextEdit()
        self.information.setReadOnly(True)
        self.information.setPlaceholderText("Select an update for its current version and paths.")
        self.activity = QPlainTextEdit()
        self.activity.setReadOnly(True)
        self.activity.document().setMaximumBlockCount(1000)
        tabs.addTab(self.information, "Information")
        tabs.addTab(self.activity, "Activity")
        splitter.addWidget(tabs)
        splitter.setStretchFactor(0, 5)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([540, 150])
        layout.addWidget(splitter, 1)

        actions = QHBoxLayout()
        self.settings_button = QPushButton("Settings")
        self.quit_button = QPushButton("Exit")
        self.refresh_button = QPushButton("Refresh")
        self.rebuild_button = QPushButton("Rebuild")
        self.settings_button.clicked.connect(self.edit_settings)
        self.quit_button.clicked.connect(self.request_quit)
        self.refresh_button.clicked.connect(self.start_refresh)
        self.rebuild_button.clicked.connect(self.confirm_rebuild)
        actions.addWidget(self.settings_button)
        actions.addWidget(self.quit_button)
        actions.addStretch()
        actions.addWidget(self.refresh_button)
        actions.addWidget(self.rebuild_button)
        layout.addLayout(actions)

    def _summary_widget(self, label: str) -> QWidget:
        widget = QWidget()
        layout = QHBoxLayout(widget)
        layout.setContentsMargins(0, 0, 20, 4)
        number = QLabel("0")
        font = number.font()
        font.setPointSize(font.pointSize() + 6)
        font.setBold(True)
        number.setFont(font)
        number.setObjectName("number")
        layout.addWidget(number)
        layout.addWidget(QLabel(label))
        return widget

    def _set_summary(self, widget: QWidget, value: int) -> None:
        number = widget.findChild(QLabel, "number")
        if number is not None:
            number.setText(str(value))

    def _icon(self) -> QIcon:
        path = environment("NIXOS_UPDATE_CHECKER_ICON")
        if path and Path(path).is_file():
            return QIcon(path)
        return self.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon)

    def _build_tray(self) -> None:
        self.tray: QSystemTrayIcon | None = None
        if not self.tray_enabled:
            return
        tray = QSystemTrayIcon(self._icon(), self)
        menu = QMenu()
        show = menu.addAction("Show")
        refresh = menu.addAction("Refresh")
        quit_action = menu.addAction("Quit")
        show.triggered.connect(self.show_and_raise)
        refresh.triggered.connect(self.start_refresh)
        quit_action.triggered.connect(self.request_quit)
        tray.setContextMenu(menu)
        tray.activated.connect(lambda _reason: self.show_and_raise())
        tray.show()
        self.tray = tray

    def validate_repository(self) -> bool:
        if not (Path(self.repository) / "flake.nix").is_file():
            QMessageBox.warning(
                self,
                "Invalid NixOS flake",
                f"No flake.nix exists in:\n{self.repository}",
            )
            return False
        return True

    def edit_settings(self) -> None:
        dialog = SettingsDialog(self, self.repository, self.settings)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        repository = canonical_path(dialog.repository.text())
        self.settings.setValue("repository", repository)
        self.settings.setValue("garbageCollectionEnabled", dialog.garbage_collection.isChecked())
        self.settings.setValue("garbageCollectionDays", dialog.retention.value())
        if repository != self.repository:
            self.repository = repository
            self.last_report = {}
            self.report_mtime_ns = 0
            self.populate_report({})
            self.load_cached_report()

    def load_cached_report(self) -> bool:
        try:
            stat = self.report_path.stat()
        except OSError:
            return False
        if stat.st_mtime_ns == self.report_mtime_ns:
            return bool(self.last_report)
        try:
            report = json.loads(self.report_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            self.append_log(f"Could not read background report: {error}")
            return False
        if not isinstance(report, dict):
            return False
        if canonical_path(str(report.get("repository", ""))) != self.repository:
            return False
        self.report_mtime_ns = stat.st_mtime_ns
        self.apply_report(report, "background service")
        return True

    def start_refresh(self) -> None:
        if self.process is not None or not self.validate_repository():
            return
        self.start_process(
            "refresh",
            environment("NIXOS_UPDATE_CHECKER_BACKEND", "check-nixos-updates"),
            ["--json", self.repository],
            "Building and comparing the candidate system…",
        )

    def confirm_rebuild(self) -> None:
        if self.process is not None or not self.validate_repository():
            return
        configuration = str(self.last_report.get("configuration", ""))
        if not configuration:
            QMessageBox.information(
                self, "Refresh required", "Refresh successfully before rebuilding."
            )
            return
        note = ""
        if self.settings.value("garbageCollectionEnabled", False, type=bool):
            days = self.settings.value("garbageCollectionDays", 30, type=int)
            note = f"\n\nGenerations older than {days} days will then be garbage collected."
        answer = QMessageBox.question(
            self,
            "Update and rebuild NixOS?",
            "This updates the real flake.lock, rebuilds, and switches the running system."
            f"{note}\n\nContinue?",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.pending_configuration = configuration
        nix = environment("NIXOS_UPDATE_CHECKER_NIX", "nix")
        arguments = ["flake", "update", "--flake", f"path:{self.repository}"]
        lock_path = Path(self.repository) / "flake.lock"
        if os.access(lock_path, os.W_OK) and os.access(self.repository, os.W_OK):
            self.start_process("update-lock", nix, arguments, "Updating flake.lock…")
        else:
            self.start_process(
                "update-lock",
                environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                [nix, *arguments],
                "Updating flake.lock…",
            )

    def start_rebuild(self) -> None:
        configuration = self.pending_configuration
        self.pending_configuration = ""
        target = f"path:{self.repository}#{configuration}"
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
        )

    def record_applied_lock(self) -> None:
        self.start_process(
            "record-applied-lock",
            environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
            [
                environment("NIXOS_UPDATE_CHECKER_BACKEND", "check-nixos-updates"),
                "--record-applied-lock",
                "--applied-lock",
                environment(
                    "NIXOS_UPDATE_CHECKER_APPLIED_LOCK",
                    "/var/lib/nixos-update-checker/applied-flake-lock.json",
                ),
                self.repository,
            ],
            "Recording the applied flake inputs…",
        )

    def continue_after_rebuild(self) -> None:
        if self.settings.value("garbageCollectionEnabled", False, type=bool):
            days = self.settings.value("garbageCollectionDays", 30, type=int)
            self.start_process(
                "garbage-collect",
                environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                [
                    environment("NIXOS_UPDATE_CHECKER_GC", "nix-collect-garbage"),
                    *garbage_collection_arguments(days),
                ],
                "Garbage collecting old generations…",
            )
            return
        self.finish_rebuild()

    def finish_rebuild(self) -> None:
        self.set_busy(False, "Rebuild complete")
        QTimer.singleShot(0, self.start_refresh)

    def start_process(self, job: str, program: str, arguments: list[str], message: str) -> None:
        self.active_job = job
        self.stdout.clear()
        self.stderr.clear()
        self.set_busy(True, message)
        self.append_log(f"$ {program} {' '.join(arguments)}")
        process = QProcess(self)
        self.process = process
        process.setWorkingDirectory(self.repository)
        process.readyReadStandardOutput.connect(self._read_stdout)
        process.readyReadStandardError.connect(self._read_stderr)
        process.finished.connect(self.process_finished)
        process.start(program, arguments)

    def _read_stdout(self) -> None:
        if self.process is None:
            return
        chunk = bytes(self.process.readAllStandardOutput())
        self.stdout.extend(chunk)
        if self.active_job != "refresh" and chunk.strip():
            self.activity.appendPlainText(chunk.decode(errors="replace").strip())

    def _read_stderr(self) -> None:
        if self.process is None:
            return
        chunk = bytes(self.process.readAllStandardError())
        self.stderr.extend(chunk)
        if chunk.strip():
            self.activity.appendPlainText(chunk.decode(errors="replace").strip())

    def process_finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        if self.process is None:
            return
        self._read_stdout()
        self._read_stderr()
        job = self.active_job
        self.process.deleteLater()
        self.process = None
        self.active_job = ""
        if exit_code != 0:
            detail = bytes(self.stderr or self.stdout).decode(errors="replace").strip()
            if job == "record-applied-lock":
                self.append_log(f"Could not save applied flake inputs: {detail}")
                self.continue_after_rebuild()
                return
            self.pending_configuration = ""
            self.set_busy(False, f"{job} failed")
            QMessageBox.critical(self, f"{job} failed", detail[-5000:])
            return
        if job == "refresh":
            try:
                report = json.loads(self.stdout)
                if not isinstance(report, dict):
                    raise ValueError("Report is not an object")
            except (json.JSONDecodeError, ValueError) as error:
                self.set_busy(False, "Invalid checker report")
                QMessageBox.critical(self, "Invalid checker report", str(error))
                return
            self.apply_report(report, "Refresh")
            self.set_busy(False, "Refresh complete")
            return
        if job == "update-lock":
            self.start_rebuild()
            return
        if job == "rebuild":
            self.record_applied_lock()
            return
        if job == "record-applied-lock":
            self.continue_after_rebuild()
            return
        if job == "garbage-collect":
            self.finish_rebuild()

    def set_busy(self, busy: bool, message: str) -> None:
        self.refresh_button.setEnabled(not busy)
        self.rebuild_button.setEnabled(not busy)
        self.settings_button.setEnabled(not busy)
        self.progress.setVisible(busy)
        self.status.setText(message)

    def apply_report(self, report: JsonObject, source: str) -> None:
        if report.get("schemaVersion") != SCHEMA_VERSION:
            self.status.setText("Unsupported report version")
            return
        self.last_report = report
        if report.get("status") != "success":
            error = report.get("error", {})
            self.status.setText(str((error or {}).get("message", "Background check failed")))
            return
        self.populate_report(report)
        generated = display_time(report.get("generatedAt"))
        build = report.get("build", {})
        elapsed = float((build or {}).get("elapsedSeconds", 0))
        mode = "background" if (build or {}).get("background") else "interactive"
        self.status.setText(f"{source} · {generated} · {mode} build {elapsed:.1f}s")
        if self.tray is not None:
            count = len(report.get("inputs", [])) + len(
                (report.get("packages", {}) or {}).get("changes", [])
            )
            self.tray.setToolTip(f"NixOS Update Checker · {count} updates")

    def add_section(self, title: str, count: int) -> None:
        item = QListWidgetItem(f"{title} ({count})")
        item.setData(SECTION_ROLE, f"{title} ({count})")
        item.setFlags(Qt.ItemFlag.ItemIsEnabled)
        self.updates.addItem(item)

    def populate_report(self, report: JsonObject) -> None:
        rows = report_rows(report)
        self.updates.clear()
        self.rendered_update_count = len(rows)
        for row_type, title in (
            ("Flake", "Flake inputs"),
            ("Package", "Packages"),
            ("Rebuild", "Rebuild-only"),
        ):
            grouped = [row for row in rows if row.get("type") == row_type]
            if not grouped:
                continue
            self.add_section(title, len(grouped))
            for row in grouped:
                item = QListWidgetItem(str(row.get("name", "")))
                item.setData(ROW_ROLE, row)
                self.updates.addItem(item)
        if not rows:
            empty = QListWidgetItem("No updates found")
            empty.setFlags(Qt.ItemFlag.NoItemFlags)
            self.updates.addItem(empty)

        packages = report.get("packages", {}) if isinstance(report, dict) else {}
        package_changes = packages.get("changes", []) if isinstance(packages, dict) else []
        store_only = packages.get("storeOnlyChanges", []) if isinstance(packages, dict) else []
        inputs = report.get("inputs", []) if isinstance(report, dict) else []
        self._set_summary(
            self.package_summary, len(package_changes) if isinstance(package_changes, list) else 0
        )
        self._set_summary(self.flake_summary, len(inputs) if isinstance(inputs, list) else 0)
        self._set_summary(
            self.rebuild_summary, len(store_only) if isinstance(store_only, list) else 0
        )
        self.information.clear()

    def update_information(
        self,
        current: QListWidgetItem | None = None,
        _previous: QListWidgetItem | None = None,
    ) -> None:
        item = current or self.updates.currentItem()
        row = item.data(ROW_ROLE) if item is not None else None
        self.information.setPlainText(
            "\n".join(update_detail_lines(row)) if isinstance(row, dict) else ""
        )

    def append_log(self, message: str) -> None:
        self.activity.appendPlainText(message)

    def show_and_raise(self) -> None:
        self.show()
        self.raise_()
        self.activateWindow()

    def request_quit(self) -> None:
        self.quit_requested = True
        if self.tray is not None:
            self.tray.hide()
        QApplication.quit()

    def closeEvent(self, event: QCloseEvent) -> None:
        if self.tray_enabled and not self.quit_requested:
            event.ignore()
            self.hide()
        else:
            event.accept()

    def run_self_test(self) -> None:
        sample = {
            "schemaVersion": SCHEMA_VERSION,
            "status": "success",
            "repository": self.repository,
            "configuration": "test",
            "generatedAt": datetime.now().astimezone().isoformat(),
            "inputs": [
                {
                    "name": "nixpkgs",
                    "before": {"display": "old"},
                    "after": {"display": "new"},
                }
            ],
            "packages": {
                "changes": [
                    {
                        "name": "hello",
                        "kind": "version",
                        "before": {"version": "1"},
                        "after": {"version": "2"},
                    }
                ],
                "storeOnlyChanges": [{"name": "glibc", "kind": "store"}],
            },
            "system": {"configurationState": "applied", "rebootPending": False},
            "build": {"elapsedSeconds": 1.2, "background": True},
        }
        self.apply_report(sample, "self-test")
        number = self.package_summary.findChild(QLabel, "number")
        has_native_frame = not bool(self.windowFlags() & Qt.WindowType.FramelessWindowHint)
        if (
            self.rendered_update_count != 3
            or number is None
            or number.text() != "1"
            or not has_native_frame
        ):
            raise RuntimeError("GUI report rendering self-test failed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open the NixOS Update Checker")
    parser.add_argument("repository", nargs="?")
    parser.add_argument(
        "--report",
        default=environment(
            "NIXOS_UPDATE_CHECKER_REPORT", "/var/lib/nixos-update-checker/report.json"
        ),
    )
    parser.add_argument("--no-tray", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--version", action="version", version=f"%(prog)s {display_version()}")
    return parser


def main(argv: list[str] | None = None) -> int:
    namespace = build_parser().parse_args(argv)
    app = QApplication(sys.argv[:1])
    app.setApplicationName("NixOS Update Checker")
    app.setOrganizationName("nixos-update-checker")
    app.setQuitOnLastWindowClosed(namespace.no_tray)
    settings = QSettings("nixos-update-checker", "nixos-update-checker")
    repository = initial_repository(
        namespace.repository,
        str(settings.value("repository", "")),
        environment("NIXOS_UPDATE_CHECKER_REPOSITORY", "."),
    )
    window = UpdateCheckerWindow(repository, namespace.report, not namespace.no_tray)
    if namespace.self_test:
        window.run_self_test()
        return 0
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
