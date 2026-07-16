from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QDateTime, QProcess, QSettings, QSize, Qt, QTimer
from PySide6.QtGui import QAction, QCloseEvent, QColor, QFont, QIcon, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QFrame,
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
    QSplitter,
    QStyle,
    QStyledItemDelegate,
    QStyleOptionViewItem,
    QSystemTrayIcon,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from . import SCHEMA_VERSION, display_version
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


def initial_repository(explicit: str | None, saved: str, configured_default: str) -> str:
    return explicit or saved or configured_default


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


class UpdateItemDelegate(QStyledItemDelegate):
    def item_option(self, option: QStyleOptionViewItem, index: Any) -> QStyleOptionViewItem:
        item_option = QStyleOptionViewItem(option)
        table = option.widget
        if isinstance(table, UpdateTableWidget) and index.row() == table.hovered_row:
            item_option.state |= QStyle.StateFlag.State_MouseOver
        return item_option

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index: Any) -> None:
        item_option = self.item_option(option, index)
        super().paint(painter, item_option, index)
        self.paint_hover_overlay(painter, item_option, index)

    def paint_hover_overlay(
        self, painter: QPainter, option: QStyleOptionViewItem, index: Any
    ) -> None:
        table = option.widget
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        if not isinstance(table, UpdateTableWidget) or index.row() != table.hovered_row or selected:
            return
        color = option.palette.highlight().color()
        color.setAlpha(30)
        painter.fillRect(option.rect, color)


class PackageNameDelegate(UpdateItemDelegate):
    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index: Any) -> None:
        item_option = self.item_option(option, index)
        self.initStyleOption(item_option, index)
        name, _, description = item_option.text.partition("\n")
        item_option.text = ""
        style = item_option.widget.style() if item_option.widget else QApplication.style()
        style.drawControl(QStyle.ControlElement.CE_ItemViewItem, item_option, painter)
        self.paint_hover_overlay(painter, item_option, index)

        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        primary = (
            option.palette.highlightedText().color() if selected else option.palette.text().color()
        )
        secondary = primary if selected else option.palette.placeholderText().color()
        text_rect = option.rect.adjusted(12, 7, -8, -5)
        painter.save()
        painter.setPen(primary)
        painter.setFont(option.font)
        visible_name = painter.fontMetrics().elidedText(
            name, Qt.TextElideMode.ElideRight, text_rect.width()
        )
        painter.drawText(
            text_rect,
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop,
            visible_name,
        )
        if description:
            secondary_font = QFont(option.font)
            secondary_font.setPointSizeF(max(7.0, option.font.pointSizeF() - 1.0))
            painter.setFont(secondary_font)
            painter.setPen(secondary)
            description_rect = text_rect.adjusted(0, 21, 0, 0)
            visible_description = painter.fontMetrics().elidedText(
                description, Qt.TextElideMode.ElideRight, description_rect.width()
            )
            painter.drawText(
                description_rect,
                Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop,
                visible_description,
            )
        painter.restore()

    def sizeHint(self, option: QStyleOptionViewItem, index: Any) -> QSize:
        size = super().sizeHint(option, index)
        return QSize(size.width(), max(56, size.height()))


class UpdateTableWidget(QTableWidget):
    def __init__(self) -> None:
        super().__init__(0, 3)
        self.hovered_row = -1
        self.setMouseTracking(True)

    def mouseMoveEvent(self, event: Any) -> None:
        self.set_hovered_row(self.rowAt(event.position().toPoint().y()))
        super().mouseMoveEvent(event)

    def leaveEvent(self, event: Any) -> None:
        self.set_hovered_row(-1)
        super().leaveEvent(event)

    def set_hovered_row(self, row: int) -> None:
        if row == self.hovered_row:
            return
        self.hovered_row = row
        self.viewport().update()


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
        self.system_window: QDialog | None = None
        self.pending_rebuild_configuration = ""

        self.setWindowIcon(self.base_icon)
        self.setWindowTitle("NixOS Update Checker")
        self.setMinimumSize(900, 640)
        self.resize(1120, 780)
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
            QTimer.singleShot(750, lambda: self.start_check(False, True))

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
        central.setObjectName("applicationSurface")
        root = QVBoxLayout(central)
        root.setContentsMargins(16, 14, 16, 10)
        root.setSpacing(10)

        command_bar = QFrame()
        command_bar.setObjectName("commandBar")
        command_layout = QHBoxLayout(command_bar)
        command_layout.setContentsMargins(14, 10, 12, 10)
        information = QHBoxLayout()
        information.setSpacing(24)
        self.package_count = self._summary_value("Package updates")
        self.flake_count = self._summary_value("Flake updates")
        self.rebuild_state = self._summary_value("Rebuild")
        information.addWidget(self.package_count)
        information.addWidget(self.flake_count)
        information.addWidget(self.rebuild_state)
        command_layout.addLayout(information)
        command_layout.addStretch()
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setFixedSize(120, 5)
        self.progress.setTextVisible(False)
        self.progress.hide()
        command_layout.addWidget(self.progress)
        self.check_button = QPushButton("Refresh")
        self.check_button.setObjectName("primaryAction")
        self.check_button.setToolTip("Build the updated system closure without applying it")
        self.check_button.clicked.connect(lambda: self.start_check(True, True))
        self.rebuild_button = QPushButton("Rebuild")
        self.rebuild_button.clicked.connect(self.confirm_rebuild)
        command_layout.addWidget(self.check_button)
        command_layout.addWidget(self.rebuild_button)
        root.addWidget(command_bar)

        self.update_table = UpdateTableWidget()
        self.update_table.setObjectName("updateTable")
        self.update_table.setHorizontalHeaderLabels(["Type", "Package", "New version"])
        self.update_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.update_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.update_table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.update_table.setAlternatingRowColors(False)
        self.update_table.setShowGrid(False)
        self.update_table.setWordWrap(True)
        self.update_table.verticalHeader().setVisible(False)
        self.update_table.verticalHeader().setDefaultSectionSize(56)
        header = self.update_table.horizontalHeader()
        header.setHighlightSections(False)
        header.setSectionsMovable(False)
        header.setStretchLastSection(True)
        header.setMinimumSectionSize(70)
        header.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        self.update_table.setColumnWidth(0, 130)
        self.update_table.setColumnWidth(1, 720)
        self.update_table.setColumnWidth(2, 170)
        self.update_table.setItemDelegate(UpdateItemDelegate(self.update_table))
        self.update_table.setItemDelegateForColumn(1, PackageNameDelegate(self.update_table))
        self.update_table.itemSelectionChanged.connect(self.update_selection_information)

        self.information_tabs = QTabWidget()
        self.information_tabs.setDocumentMode(True)
        self.information_tabs.addTab(self._build_information_panel(), "Information")
        self.information_tabs.addTab(self._build_activity_panel(), "Activity")

        splitter = QSplitter(Qt.Orientation.Vertical)
        splitter.setChildrenCollapsible(False)
        splitter.addWidget(self.update_table)
        splitter.addWidget(self.information_tabs)
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 0)
        splitter.setSizes([590, 145])
        root.addWidget(splitter, 1)
        self.setCentralWidget(central)
        self.status_message = QLabel("Idle")
        self.statusBar().addWidget(self.status_message, 1)
        self.last_checked = QLabel("Last checked: never")
        self.last_checked.setObjectName("mutedText")
        self.statusBar().addPermanentWidget(self.last_checked)
        self.setStyleSheet(
            "QWidget#applicationSurface { background: palette(base); } "
            "QFrame#commandBar { border: 1px solid palette(mid); border-radius: 7px; "
            "background: palette(alternate-base); } "
            "QLabel#summaryLabel { font-size: 12px; } "
            "QLabel#summaryLabel::first-line { font-weight: 700; } "
            "QLabel#informationTitle { font-size: 16px; font-weight: 650; } "
            "QLabel#mutedText { color: palette(mid); } "
            "QPushButton, QToolButton { min-height: 30px; padding: 2px 12px; } "
            "QPushButton#primaryAction { background: #2673d9; color: white; border: none; "
            "border-radius: 5px; font-weight: 650; padding: 4px 16px; } "
            "QPushButton#primaryAction:hover { background: #3583eb; } "
            "QHeaderView::section { padding: 10px 12px; border: none; "
            "border-bottom: 1px solid palette(mid); "
            "font-weight: 650; } "
            "QTableWidget#updateTable { border: 1px solid palette(mid); "
            "selection-background-color: palette(highlight); "
            "selection-color: palette(highlighted-text); } "
            "QTableWidget#updateTable::item { padding: 8px 12px; border: none; } "
            "QProgressBar { border: none; background: palette(alternate-base); } "
            "QProgressBar::chunk { background: #3daee9; }"
        )

    def _summary_value(self, label: str) -> QLabel:
        value = QLabel()
        value.setObjectName("summaryLabel")
        self.set_summary_value(value, "0", label)
        return value

    def set_summary_value(self, widget: QLabel, value: str, label: str) -> None:
        widget.setProperty("summaryValue", value)
        widget.setText(
            f'<span style="font-size: 21px; font-weight: 700">{value}</span><br>'
            f'<span style="font-size: 11px">{label}</span>'
        )

    def _build_information_panel(self) -> QWidget:
        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(10, 8, 10, 8)
        self.information_title = QLabel("Select an update")
        self.information_title.setObjectName("informationTitle")
        self.information_description = QLabel(
            "Select a row above to see its current version and source details."
        )
        self.information_description.setObjectName("mutedText")
        self.information_description.setWordWrap(True)
        details = QHBoxLayout()
        self.information_type = QLabel("Type: —")
        self.information_current = QLabel("Current: —")
        self.information_available = QLabel("Available: —")
        details.addWidget(self.information_type)
        details.addWidget(self.information_current)
        details.addWidget(self.information_available)
        details.addStretch()
        layout.addWidget(self.information_title)
        layout.addWidget(self.information_description)
        layout.addLayout(details)
        self.information_list = QPlainTextEdit()
        self.information_list.setReadOnly(True)
        self.information_list.setVisible(False)
        layout.addWidget(self.information_list, 1)
        layout.addStretch()
        return panel

    def _build_activity_panel(self) -> QWidget:
        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(6, 6, 6, 6)
        self.activity = QPlainTextEdit()
        self.activity.setReadOnly(True)
        self.activity.document().setMaximumBlockCount(3000)
        header = QHBoxLayout()
        heading = QLabel("Activity log")
        heading.setObjectName("sectionTitle")
        header.addWidget(heading)
        header.addStretch()
        clear = QPushButton("Clear")
        clear.clicked.connect(self.activity.clear)
        header.addWidget(clear)
        layout.addLayout(header)
        layout.addWidget(self.activity)
        return panel

    def _add_action(self, menu: QMenu, text: str, callback: Any) -> QAction:
        action = QAction(text, self)
        action.triggered.connect(callback)
        menu.addAction(action)
        return action

    def _build_menus(self) -> None:
        file_menu = self.menuBar().addMenu("&File")
        self._add_action(file_menu, "Settings…", self.edit_settings)
        self._add_action(file_menu, "System state…", self.show_system_state)
        file_menu.addSeparator()
        self._add_action(file_menu, "Hide to tray", self.hide)
        file_menu.addSeparator()
        self._add_action(file_menu, "Quit", self.request_quit)
        actions = self.menuBar().addMenu("&Actions")
        self._add_action(actions, "Refresh", lambda: self.start_check(True, True))
        self._add_action(actions, "Rebuild", self.confirm_rebuild)
        help_menu = self.menuBar().addMenu("&Help")
        self._add_action(
            help_menu,
            "About",
            lambda: QMessageBox.about(
                self,
                "About NixOS Update Checker",
                f"<b>NixOS Update Checker {display_version()}</b><br><br>"
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
        self._add_action(menu, "Refresh", lambda: self.start_check(True, True))
        self._add_action(menu, "Rebuild…", self.confirm_rebuild)
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

    def set_repository(self, repository: str) -> None:
        repository = canonical_path(repository)
        if repository == self.repository:
            return
        self.repository = repository
        self.settings.setValue("repository", repository)
        self.report_mtime_ns = 0
        self.last_report = {}
        self.update_table.setRowCount(0)
        self.set_summary_value(self.package_count, "0", "Package updates")
        self.set_summary_value(self.flake_count, "0", "Flake updates")
        self.set_summary_value(self.rebuild_state, "Unknown", "Rebuild")
        self.clear_selection_information()
        self.status_message.setText("Configuration source changed; refresh to check it")

    def show_system_state(self) -> None:
        if self.system_window is None:
            window = QDialog(self)
            window.setWindowTitle("NixOS system state")
            window.resize(650, 420)
            layout = QVBoxLayout(window)
            form = QFormLayout()
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
                value.setWordWrap(True)
                self.system_values[key] = value
                form.addRow(f"{label}:", value)
            layout.addLayout(form)
            explanation = QLabel(
                "The checker selects the NixOS configuration matching this machine and "
                "compares it with the currently running system."
            )
            explanation.setWordWrap(True)
            layout.addWidget(explanation)
            layout.addStretch()
            close = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
            close.rejected.connect(window.close)
            layout.addWidget(close)
            self.system_window = window
        self.populate_system(self.last_report)
        self.system_window.show()
        self.system_window.raise_()
        self.system_window.activateWindow()

    def validate_target(self, interactive: bool = True) -> bool:
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
        if self.process is not None:
            return
        try:
            current = self.read_repository_settings()
        except SettingsError as error:
            QMessageBox.critical(self, "Could not read settings", str(error))
            return

        dialog = QDialog(self)
        dialog.setWindowTitle("NixOS Update Checker settings")
        dialog.resize(680, 590)
        layout = QVBoxLayout(dialog)
        source_label = QLabel("NixOS configuration source")
        source_label.setObjectName("informationTitle")
        layout.addWidget(source_label)
        source_layout = QHBoxLayout()
        repository_edit = QLineEdit(self.repository)
        source_layout.addWidget(repository_edit, 1)
        browse = QToolButton()
        browse.setText("Browse…")

        def choose_source() -> None:
            selected = QFileDialog.getExistingDirectory(
                dialog, "Choose NixOS flake", repository_edit.text()
            )
            if selected:
                repository_edit.setText(selected)

        browse.clicked.connect(choose_source)
        source_layout.addWidget(browse)
        layout.addLayout(source_layout)
        source_help = QLabel(
            "This per-user choice is used by the GUI. The NixOS module separately "
            "configures the source used by its background service."
        )
        source_help.setWordWrap(True)
        source_help.setStyleSheet("color: palette(mid);")
        layout.addWidget(source_help)

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
            "Garbage collection runs only after Rebuild succeeds. It removes old "
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

        repository = canonical_path(repository_edit.text().strip())
        repository_path = Path(repository)
        if (
            not (repository_path / "flake.nix").exists()
            or not (repository_path / "flake.lock").exists()
        ):
            QMessageBox.critical(
                self,
                "Invalid NixOS configuration source",
                f"{repository} must contain both flake.nix and flake.lock.",
            )
            return
        self.set_repository(repository)

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
        self.start_check(False, True)

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
            "Update and rebuild NixOS?",
            "This will update the flake lock file, then request administrator "
            "authorization to rebuild and switch the running system."
            f"{garbage_collection_note}\n\nContinue?",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.pending_rebuild_configuration = configuration
        lock_path = Path(self.repository) / "flake.lock"
        authorization = not os.access(lock_path, os.W_OK) or not os.access(self.repository, os.W_OK)
        nix = environment("NIXOS_UPDATE_CHECKER_NIX", "nix")
        arguments = ["flake", "update", "--flake", f"path:{self.repository}"]
        if authorization:
            self.start_process(
                "update-for-rebuild",
                environment("NIXOS_UPDATE_CHECKER_PKEXEC", "pkexec"),
                [nix, *arguments],
                "Updating the lock file before rebuilding…",
                True,
            )
        else:
            self.start_process(
                "update-for-rebuild",
                nix,
                arguments,
                "Updating the lock file before rebuilding…",
                True,
            )

    def start_rebuild(self) -> None:
        configuration = self.pending_rebuild_configuration
        self.pending_rebuild_configuration = ""
        if not configuration:
            self.set_busy(False, "Rebuild configuration was lost")
            return
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
            if job == "update-for-rebuild":
                self.pending_rebuild_configuration = ""
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
            QTimer.singleShot(0, lambda: self.start_check(False, True))
            return
        if job == "update-for-rebuild":
            self.start_rebuild()
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
        if job == "garbage-collect":
            label = "System rebuild and garbage collection complete"
        else:
            label = "System rebuild complete"
        self.set_busy(False, label)
        QTimer.singleShot(0, lambda: self.start_check(False, True))

    def cleanup_pending_settings(self) -> None:
        if self.pending_settings_temp is not None:
            self.pending_settings_temp.unlink(missing_ok=True)
            self.pending_settings_temp = None

    def set_busy(self, busy: bool, message: str) -> None:
        for widget in (self.check_button, self.rebuild_button):
            widget.setEnabled(not busy)
        self.progress.setVisible(busy)
        self.status_message.setText(message)
        if busy:
            self.set_tray_state("busy")

    def apply_report(self, report: JsonObject, source: str, notify: bool) -> None:
        if report.get("schemaVersion") != SCHEMA_VERSION:
            self.status_message.setText("Unsupported checker report; upgrade GUI and backend")
            self.set_tray_state("error")
            return
        if report.get("status") != "success":
            error = report.get("error", {})
            self.status_message.setText(str(error.get("message", "The background checker failed.")))
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
        package_updates = [*packages, *dependencies]
        store_only = [
            change
            for change in [*reported_packages, *reported_dependencies]
            if change.get("kind") == "store"
        ]
        store_only.extend(packages_object.get("storeOnlyChanges", []))
        system = report.get("system", {})
        build = report.get("build", {})
        updates = bool(report.get("updatesAvailable"))
        rebuild = system.get("configurationState") == "differs"
        self.set_summary_value(self.package_count, str(len(package_updates)), "Package updates")
        self.set_summary_value(self.flake_count, str(len(inputs)), "Flake updates")
        self.set_summary_value(self.rebuild_state, "Yes" if rebuild else "No", "Rebuild")
        self.populate_updates(package_updates, inputs, store_only)
        if updates:
            source_label = "full build" if build.get("performed") else "fast evaluation"
            notification_text = (
                f"{len(package_updates)} package and {len(inputs)} flake updates "
                f"from {source_label}"
            )
            self.status_message.setText(notification_text)
            self.set_tray_state("updates", len(package_updates) or len(inputs))
        elif rebuild:
            notification_text = "Configuration changes are ready to rebuild"
            self.status_message.setText(notification_text)
            self.set_tray_state("rebuild")
        else:
            notification_text = "The running system is up to date"
            self.status_message.setText(notification_text)
            self.set_tray_state("current")
        generated = str(report.get("generatedAt", ""))
        self.last_checked.setText(f"Last checked: {display_time(generated)}")
        self.populate_system(report)
        for option in packages_object.get("unresolvedOptions", []):
            self.append_log(f"Configured package option was not found: {option}")
        if notify and self.tray is not None and generated != self.last_notified:
            self.last_notified = generated
            if updates:
                self.tray.showMessage(
                    "NixOS updates available",
                    notification_text,
                    QSystemTrayIcon.MessageIcon.Information,
                    9000,
                )
            elif rebuild:
                self.tray.showMessage(
                    "NixOS rebuild available",
                    notification_text,
                    QSystemTrayIcon.MessageIcon.Information,
                    9000,
                )

    def populate_updates(
        self,
        packages: list[JsonObject],
        inputs: list[JsonObject],
        store_changes: list[JsonObject],
    ) -> None:
        rows: list[JsonObject] = []
        for change in packages:
            after = change.get("after")
            before = change.get("before")
            description = str(
                change.get("description")
                or (after or {}).get("description")
                or (before or {}).get("description")
                or ""
            )
            available = "removed" if change.get("kind") == "removed" else package_version(after)
            channel = str(
                change.get("channel")
                or (after or {}).get("channel")
                or (before or {}).get("channel")
                or "unknown"
            )
            rows.append(
                {
                    "type": f"nixPkg · {channel}",
                    "name": str(change.get("name", "")),
                    "description": description,
                    "current": package_version(before),
                    "available": available,
                    "sortGroup": 1,
                }
            )
        for change in inputs:
            after = input_revision(change.get("after"))
            rows.append(
                {
                    "type": "flake",
                    "name": str(change.get("name", "")),
                    "description": "Flake input",
                    "current": input_revision(change.get("before")),
                    "available": "removed" if after == "missing" else after,
                    "sortGroup": 0,
                }
            )
        if store_changes:
            rows.append(
                {
                    "type": "rebuild",
                    "name": "Rebuild-only package changes",
                    "description": (
                        f"{len(store_changes)} packages changed store paths without "
                        "changing versions"
                    ),
                    "current": f"{len(store_changes)} current store paths",
                    "available": f"{len(store_changes)} packages",
                    "storeChanges": store_changes,
                    "sortGroup": 2,
                }
            )
        rows.sort(
            key=lambda update: (
                int(update["sortGroup"]),
                str(update["type"]).casefold(),
                str(update["name"]).casefold(),
            )
        )
        self.update_table.set_hovered_row(-1)
        self.update_table.clearSelection()
        self.update_table.setRowCount(len(rows))
        for row, update in enumerate(rows):
            type_item = QTableWidgetItem(str(update["type"]))
            name_text = str(update["name"])
            if update["description"]:
                name_text += f"\n{update['description']}"
            name_item = QTableWidgetItem(name_text)
            available_item = QTableWidgetItem(str(update["available"]))
            type_item.setData(Qt.ItemDataRole.UserRole, update)
            self.update_table.setItem(row, 0, type_item)
            self.update_table.setItem(row, 1, name_item)
            self.update_table.setItem(row, 2, available_item)
        self.clear_selection_information()

    def clear_selection_information(self) -> None:
        self.information_title.setText("Select an update")
        self.information_description.setText(
            "Select a row above to see its current version and source details."
        )
        self.information_type.setText("Type: —")
        self.information_current.setText("Current: —")
        self.information_available.setText("Available: —")
        self.information_list.clear()
        self.information_list.setVisible(False)

    def update_selection_information(self) -> None:
        rows = self.update_table.selectionModel().selectedRows()
        if not rows:
            self.clear_selection_information()
            return
        item = self.update_table.item(rows[0].row(), 0)
        update = item.data(Qt.ItemDataRole.UserRole)
        if not isinstance(update, dict):
            self.clear_selection_information()
            return
        self.information_title.setText(str(update.get("name", "")))
        self.information_description.setText(
            str(update.get("description") or "No package description is available.")
        )
        self.information_type.setText(f"Type: {update.get('type', '—')}")
        self.information_current.setText(f"Current: {update.get('current', '—')}")
        self.information_available.setText(f"Available: {update.get('available', '—')}")
        store_changes = update.get("storeChanges", [])
        if isinstance(store_changes, list) and store_changes:
            lines = []
            for change in store_changes:
                if not isinstance(change, dict):
                    continue
                current = package_version(change.get("before"))
                available = package_version(change.get("after"))
                lines.append(f"{change.get('name', 'unknown')}: {current} → {available}")
            self.information_list.setPlainText("\n".join(lines))
            self.information_list.setVisible(True)
        else:
            self.information_list.clear()
            self.information_list.setVisible(False)

    def populate_system(self, report: JsonObject) -> None:
        if not self.system_values:
            return
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
                        "after": {
                            "version": "2.0",
                            "description": "Example package description",
                        },
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
        self.update_table.selectRow(1)
        selected_current = self.information_current.text()
        self.update_table.selectRow(3)
        store_information_rendered = (
            not self.information_list.isHidden()
            and "rebuilt-example" in self.information_list.toPlainText()
        )
        self.show_system_state()
        system_state_rendered = self.system_values["runningGeneration"].text() == "system-1-link"
        if self.system_window is not None:
            self.system_window.close()
        if (
            self.update_table.rowCount() != 4
            or self.update_table.columnCount() != 3
            or self.update_table.item(0, 0).text() != "flake"
            or self.update_table.item(3, 0).text() != "rebuild"
            or self.package_count.property("summaryValue") != "2"
            or self.flake_count.property("summaryValue") != "1"
            or self.rebuild_state.property("summaryValue") != "No"
            or selected_current != "Current: 1.0"
            or not store_information_rendered
            or self.update_table.selectionBehavior() != QTableWidget.SelectionBehavior.SelectRows
            or self.update_table.horizontalHeader().sectionResizeMode(0)
            != QHeaderView.ResizeMode.Interactive
            or not isinstance(self.update_table.itemDelegate(), UpdateItemDelegate)
            or not isinstance(self.update_table.itemDelegateForColumn(1), PackageNameDelegate)
            or not system_state_rendered
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
    parser.add_argument("--version", action="version", version=f"%(prog)s {display_version()}")
    return parser


def main(argv: list[str] | None = None) -> int:
    namespace = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    app = QApplication([sys.argv[0]])
    app.setApplicationName("NixOS Update Checker")
    app.setApplicationDisplayName("NixOS Update Checker")
    app.setOrganizationName("nixos-update-checker")
    app.setApplicationVersion(display_version())
    application_settings = QSettings("nixos-update-checker", "nixos-update-checker")
    saved_repository = str(application_settings.value("repository", "") or "")
    repository = initial_repository(
        namespace.repository,
        saved_repository,
        environment("NIXOS_UPDATE_CHECKER_REPOSITORY", "/etc/nixos"),
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
