#include <QAbstractItemView>
#include <QApplication>
#include <QCloseEvent>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFrame>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QMouseEvent>
#include <QPainter>
#include <QPaintEvent>
#include <QPlainTextEdit>
#include <QProcess>
#include <QPushButton>
#include <QScrollBar>
#include <QSettings>
#include <QSplitter>
#include <QStandardPaths>
#include <QStyle>
#include <QSystemTrayIcon>
#include <QTableWidget>
#include <QTabWidget>
#include <QTextCursor>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

namespace {

constexpr auto Version = "4.1.1";
constexpr int DetailRole = Qt::UserRole;

struct AppSettings {
    QString reportPath;
    bool trayEnabled = true;
};

QString environment(const char *name, const QString &fallback = {})
{
    const QString value = qEnvironmentVariable(name);
    return value.isEmpty() ? fallback : value;
}

QString settingsPath()
{
    const QString configHome = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    return QDir(configHome).filePath("nixos-update-checker/nixos-update-checker.conf");
}

AppSettings loadSettings()
{
    const QString path = settingsPath();
    QSettings settings(path, QSettings::IniFormat);

    // Older Python releases stored window placement as a user preference. The
    // native window manager should decide placement, so remove that obsolete key.
    if (settings.contains("windowGeometry")) {
        settings.remove("windowGeometry");
        settings.sync();
        if (settings.allKeys().isEmpty())
            QFile::remove(path);
    }

    AppSettings result;
    result.reportPath = settings.value("reportPath").toString().trimmed();
    result.trayEnabled = settings.value("trayEnabled", true).toBool();
    return result;
}

QString canonicalPath(const QString &path)
{
    return QFileInfo(path).canonicalFilePath();
}

QString nixStorePackage(const QString &path)
{
    const QString resolved = canonicalPath(path);
    const QString prefix = "/nix/store/";
    if (!resolved.startsWith(prefix))
        return {};
    const qsizetype end = resolved.indexOf('/', prefix.size());
    return end < 0 ? resolved : resolved.left(end);
}

QString plural(int count, const QString &singular)
{
    return QString::number(count) + " " + (count == 1 ? singular : singular + "s");
}

QString timestamp(const QJsonValue &value)
{
    const QDateTime parsed = QDateTime::fromString(value.toString(), Qt::ISODate);
    return parsed.isValid() ? parsed.toLocalTime().toString("yyyy-MM-dd HH:mm") : value.toString();
}

QString formatBytes(qint64 bytes, bool signedValue = false)
{
    const QStringList units{"B", "KiB", "MiB", "GiB", "TiB"};
    const bool negative = bytes < 0;
    double value = negative ? -static_cast<double>(bytes) : static_cast<double>(bytes);
    int unit = 0;
    while (value >= 1024.0 && unit < units.size() - 1) {
        value /= 1024.0;
        ++unit;
    }
    const int precision = unit > 0 && value < 10.0 ? 1 : 0;
    QString prefix;
    if (negative)
        prefix = "−";
    else if (signedValue && bytes > 0)
        prefix = "+";
    return prefix + QString::number(value, 'f', precision) + " " + units.at(unit);
}

QStringList versions(const QJsonValue &side)
{
    QStringList result;
    if (!side.isObject())
        return result;
    for (const QJsonValue &value : side.toObject().value("versions").toArray())
        result << value.toString();
    return result;
}

QStringList storePaths(const QJsonValue &side)
{
    QStringList result;
    if (!side.isObject())
        return result;
    for (const QJsonValue &value : side.toObject().value("paths").toArray())
        result << value.toString();
    return result;
}

QString versionSummary(const QJsonObject &change)
{
    if (!change.value("after").isObject())
        return "Removed";

    const QStringList current = versions(change.value("before"));
    const QStringList candidate = versions(change.value("after"));
    if (candidate.isEmpty())
        return "Unversioned";
    if (candidate.size() == 1)
        return candidate.first();

    QString first;
    for (const QString &version : candidate) {
        if (!current.contains(version)) {
            first = version;
            break;
        }
    }
    if (first.isEmpty())
        first = candidate.first();
    return first + " +" + QString::number(candidate.size() - 1) + " more";
}

QString versionLines(const QString &title, const QStringList &values)
{
    QStringList lines{title + ":"};
    if (values.isEmpty())
        lines << "  none";
    else
        for (const QString &value : values)
            lines << "  " + value;
    return lines.join('\n');
}

QString inputDetails(const QJsonObject &change)
{
    const QJsonObject before = change.value("before").toObject();
    const QJsonObject after = change.value("after").toObject();
    QStringList lines{
        "Input: " + change.value("name").toString(),
        "",
        "Baseline: " + before.value("display").toString("missing"),
        "Candidate: " + after.value("display").toString("missing"),
    };
    if (!before.value("url").toString().isEmpty())
        lines << "Baseline source: " + before.value("url").toString();
    if (!after.value("url").toString().isEmpty())
        lines << "Candidate source: " + after.value("url").toString();
    return lines.join('\n');
}

QString packageDetails(const QJsonObject &change)
{
    const QJsonValue before = change.value("before");
    const QJsonValue after = change.value("after");
    QStringList lines{
        change.value("name").toString(),
        "",
        versionLines("Current versions", versions(before)),
        "",
        versionLines("Candidate versions", versions(after)),
        "",
    };
    if (change.value("sizeKnown").toBool()) {
        lines << "Net closure change: " + formatBytes(change.value("deltaBytes").toInteger(), true)
              << "Added to candidate closure: " + formatBytes(change.value("addedBytes").toInteger())
              << "No longer referenced by candidate: "
                     + formatBytes(change.value("removedBytes").toInteger());
    } else {
        lines << "Closure size: available after Build Update";
    }
    lines << "Preview confidence: " + change.value("confidence").toString("confirmed");
    if (after.isObject() && change.value("sizeKnown").toBool())
        lines << "Candidate total: " + formatBytes(after.toObject().value("narSize").toInteger());

    const QStringList oldPaths = storePaths(before);
    const QStringList newPaths = storePaths(after);
    if (!oldPaths.isEmpty())
        lines << "" << "Current store paths:" << oldPaths;
    if (!newPaths.isEmpty())
        lines << "" << "Candidate store paths:" << newPaths;
    return lines.join('\n');
}

QString rebuildDetails(const QJsonObject &rebuilds)
{
    QStringList lines{
        "Rebuilt packages (" + QString::number(rebuilds.value("count").toInt()) + ")",
        "",
    };
    if (rebuilds.value("sizeKnown").toBool()) {
        lines << "Net closure change: " + formatBytes(rebuilds.value("deltaBytes").toInteger(), true)
              << "Added to candidate closure: " + formatBytes(rebuilds.value("addedBytes").toInteger())
              << "No longer referenced by candidate: "
                     + formatBytes(rebuilds.value("removedBytes").toInteger());
    } else {
        lines << "Closure size: available after Build Update";
    }
    lines << "";
    for (const QJsonValue &value : rebuilds.value("items").toArray()) {
        const QJsonObject item = value.toObject();
        QStringList itemVersions;
        for (const QJsonValue &version : item.value("versions").toArray())
            itemVersions << version.toString();
        lines << item.value("name").toString() + " — " + itemVersions.join(", ");
    }
    return lines.join('\n');
}

class BusyIndicator final : public QWidget
{
public:
    explicit BusyIndicator(QWidget *parent = nullptr)
        : QWidget(parent)
    {
        setAttribute(Qt::WA_TranslucentBackground);
        setFixedSize(170, 46);
        connect(&timer_, &QTimer::timeout, this, [this] {
            step_ = (step_ + 1) % 12;
            update();
        });
    }

    void setRunning(bool running, const QString &text)
    {
        text_ = text;
        setVisible(running);
        if (running) {
            timer_.start(80);
            raise();
        } else {
            timer_.stop();
        }
    }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing);
        QColor background = palette().color(QPalette::Base);
        background.setAlpha(235);
        painter.setPen(Qt::NoPen);
        painter.setBrush(background);
        painter.drawRoundedRect(rect().adjusted(1, 1, -1, -1), 8, 8);

        const QPointF center(24, height() / 2.0);
        const QColor color = palette().color(QPalette::Highlight);
        for (int index = 0; index < 12; ++index) {
            QColor spoke = color;
            spoke.setAlpha(35 + 220 * ((index + step_) % 12) / 11);
            painter.setPen(QPen(spoke, 2.4, Qt::SolidLine, Qt::RoundCap));
            painter.save();
            painter.translate(center);
            painter.rotate(index * 30.0);
            painter.drawLine(QPointF(0, -7), QPointF(0, -13));
            painter.restore();
        }
        painter.setPen(palette().color(QPalette::Text));
        painter.drawText(QRect(44, 0, width() - 52, height()), Qt::AlignVCenter, text_);
    }

private:
    QTimer timer_;
    int step_ = 0;
    QString text_;
};

class UpdateTable final : public QTableWidget
{
public:
    explicit UpdateTable(QWidget *parent = nullptr)
        : QTableWidget(0, 3, parent)
    {
        setMouseTracking(true);
        viewport()->setMouseTracking(true);

        busy_ = new BusyIndicator(viewport());
        busy_->hide();
    }

    void setBusy(bool busy, const QString &text = {})
    {
        busy_->setRunning(busy, text);
        positionBusyIndicator();
    }

protected:
    void mouseMoveEvent(QMouseEvent *event) override
    {
        const int row = indexAt(event->position().toPoint()).row();
        if (row != hoveredRow_) {
            hoveredRow_ = row;
            viewport()->update();
        }
        QTableWidget::mouseMoveEvent(event);
    }

    void leaveEvent(QEvent *event) override
    {
        hoveredRow_ = -1;
        viewport()->update();
        QTableWidget::leaveEvent(event);
    }

    void paintEvent(QPaintEvent *event) override
    {
        QTableWidget::paintEvent(event);
        if (hoveredRow_ < 0 || selectionModel()->isRowSelected(hoveredRow_, QModelIndex{}))
            return;

        const QModelIndex first = model()->index(hoveredRow_, 0);
        const QRect rowRect(0, visualRect(first).top(), viewport()->width(), rowHeight(hoveredRow_));
        QColor hover = palette().color(QPalette::Highlight);
        hover.setAlpha(28);
        QPainter painter(viewport());
        painter.fillRect(rowRect, hover);
    }

    void resizeEvent(QResizeEvent *event) override
    {
        QTableWidget::resizeEvent(event);
        positionBusyIndicator();
    }

private:
    void positionBusyIndicator()
    {
        busy_->move((viewport()->width() - busy_->width()) / 2,
            (viewport()->height() - busy_->height()) / 2);
    }

    int hoveredRow_ = -1;
    BusyIndicator *busy_ = nullptr;
};

class MainWindow final : public QMainWindow
{
public:
    MainWindow(QString reportPath, bool trayEnabled)
        : reportPath_(std::move(reportPath))
        , statusPath_(environment("NIXOS_UPDATE_CHECKER_STATUS",
              "/var/lib/nixos-update-checker/status.json"))
        , runningPackage_(nixStorePackage(QCoreApplication::applicationFilePath()))
        , trayEnabled_(trayEnabled)
    {
        setWindowTitle("NixOS Update Checker");
        resize(840, 650);
        setMinimumSize(640, 440);
        buildInterface();
        buildTray();

        connect(&pollTimer_, &QTimer::timeout, this, [this] {
            loadReport(false);
            loadOperationStatus(false);
            refreshLiveSystemState();
            checkForReplacement();
            pollServiceState();
        });
        pollTimer_.start(3000);
        loadReport(true);
        loadOperationStatus(true);
        refreshLiveSystemState();
        checkForReplacement();
        pollServiceState();
        updatePresentation();
    }

protected:
    void closeEvent(QCloseEvent *event) override
    {
        if (trayEnabled_ && !quitRequested_) {
            hide();
            event->ignore();
            return;
        }
        event->accept();
    }

private:
    void buildInterface()
    {
        auto *central = new QWidget(this);
        auto *layout = new QVBoxLayout(central);
        layout->setContentsMargins(18, 16, 18, 16);
        layout->setSpacing(10);

        restartBanner_ = new QFrame(central);
        restartBanner_->setFrameShape(QFrame::StyledPanel);
        auto *restartLayout = new QHBoxLayout(restartBanner_);
        restartLayout->setContentsMargins(10, 7, 10, 7);
        auto *restartLabel = new QLabel(
            "A new version of NixOS Update Checker is installed.", restartBanner_);
        restartButton_ = new QPushButton("Restart", restartBanner_);
        restartLayout->addWidget(restartLabel, 1);
        restartLayout->addWidget(restartButton_);
        restartBanner_->hide();
        layout->addWidget(restartBanner_);

        summary_ = new QLabel("No report yet", central);
        QFont summaryFont = summary_->font();
        summaryFont.setPointSize(summaryFont.pointSize() + 3);
        summaryFont.setBold(true);
        summary_->setFont(summaryFont);
        layout->addWidget(summary_);

        generationStatus_ = new QLabel(central);
        generationStatus_->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(generationStatus_);

        auto *actions = new QHBoxLayout;
        status_ = new QLabel("Waiting for a report", central);
        status_->setTextInteractionFlags(Qt::TextSelectableByMouse);
        status_->setWordWrap(true);
        refreshButton_ = new QPushButton("Refresh", central);
        bootButton_ = new QPushButton("Install for Next Boot", central);
        updateButton_ = new QPushButton("Update", central);
        actions->addWidget(status_, 1);
        actions->addWidget(refreshButton_);
        actions->addWidget(bootButton_);
        actions->addWidget(updateButton_);
        layout->addLayout(actions);

        auto *splitter = new QSplitter(Qt::Vertical, central);
        splitter->setChildrenCollapsible(false);
        splitter->setHandleWidth(12);
        updates_ = new UpdateTable(splitter);
        updates_->setHorizontalHeaderLabels({"Package", "New version", "Size"});
        updates_->setAlternatingRowColors(false);
        updates_->setShowGrid(false);
        updates_->setEditTriggers(QAbstractItemView::NoEditTriggers);
        updates_->setSelectionBehavior(QAbstractItemView::SelectRows);
        updates_->setSelectionMode(QAbstractItemView::SingleSelection);
        updates_->setTextElideMode(Qt::ElideRight);
        updates_->setStyleSheet(
            "QTableView::item { border: 0; padding-left: 8px; padding-right: 8px; }");
        updates_->verticalHeader()->hide();
        updates_->verticalHeader()->setDefaultSectionSize(40);
        updates_->horizontalHeader()->setSectionsMovable(false);
        updates_->horizontalHeader()->setSectionsClickable(false);
        updates_->horizontalHeader()->setSectionResizeMode(QHeaderView::Interactive);
        updates_->horizontalHeader()->setStretchLastSection(true);
        updates_->setColumnWidth(0, 500);
        updates_->setColumnWidth(1, 190);
        updates_->setColumnWidth(2, 110);

        infoTabs_ = new QTabWidget(splitter);
        details_ = new QPlainTextEdit(infoTabs_);
        details_->setReadOnly(true);
        details_->setPlaceholderText("Select an update to see its details.");
        progress_ = new QPlainTextEdit(infoTabs_);
        progress_->setReadOnly(true);
        progress_->setPlaceholderText("Service output will appear here.");
        infoTabs_->addTab(details_, "Details");
        infoTabs_->addTab(progress_, "Progress");
        splitter->addWidget(updates_);
        splitter->addWidget(infoTabs_);
        splitter->setStretchFactor(0, 3);
        splitter->setStretchFactor(1, 1);
        splitter->setSizes({460, 150});
        layout->addWidget(splitter, 1);

        auto *versionLabel = new QLabel("Version " + QString::fromUtf8(Version), central);
        layout->addWidget(versionLabel, 0, Qt::AlignLeft);

        setCentralWidget(central);

        connect(updates_, &QTableWidget::cellClicked, this,
                [this](int row, int) {
                    const QTableWidgetItem *item = row >= 0 ? updates_->item(row, 0) : nullptr;
                    details_->setPlainText(item ? item->data(DetailRole).toString() : QString{});
                    infoTabs_->setCurrentWidget(details_);
                });
        connect(refreshButton_, &QPushButton::clicked, this, [this] {
            if (isRefreshing())
                cancelService(activeRefreshService(), "refresh");
            else
                startCheck();
        });
        connect(updateButton_, &QPushButton::clicked, this, [this] {
            if (isBuilding())
                cancelService(buildService(), "build");
            else
                startUpdateAction();
        });
        connect(bootButton_, &QPushButton::clicked, this, [this] { confirmBoot(); });
        connect(restartButton_, &QPushButton::clicked, this, [this] { restartApplication(); });
        updateButtons();
    }

    QIcon applicationIcon() const
    {
        return QIcon::fromTheme("system-software-update",
            style()->standardIcon(QStyle::SP_BrowserReload));
    }

    void buildTray()
    {
        setWindowIcon(applicationIcon());
        if (!trayEnabled_)
            return;

        tray_ = new QSystemTrayIcon(applicationIcon(), this);
        auto *menu = new QMenu(this);
        auto *showAction = menu->addAction("Show");
        trayRefreshAction_ = menu->addAction("Refresh");
        menu->addSeparator();
        auto *quitAction = menu->addAction("Quit");
        connect(showAction, &QAction::triggered, this, [this] { showAndRaise(); });
        connect(trayRefreshAction_, &QAction::triggered, this, [this] { startCheck(); });
        connect(quitAction, &QAction::triggered, this, [this] {
            quitRequested_ = true;
            tray_->hide();
            QApplication::quit();
        });
        connect(tray_, &QSystemTrayIcon::activated, this,
                [this](QSystemTrayIcon::ActivationReason reason) {
                    if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick)
                        showAndRaise();
                });
        tray_->setContextMenu(menu);
        tray_->setToolTip("NixOS Update Checker");
        tray_->show();
    }

    void showAndRaise()
    {
        show();
        raise();
        activateWindow();
    }

    void startCheck()
    {
        startService(checkerService(), "refresh");
    }

    void startUpdateAction()
    {
        if (analysisMode_ == "preview") {
            if (canBuild() && !serviceBusy())
                startService(buildService(), "build");
            return;
        }
        confirmApply();
    }

    void confirmApply()
    {
        if (!canApply() || serviceBusy())
            return;
        const auto answer = QMessageBox::question(this, "Update NixOS?",
            "This will update the real flake.lock, rebuild the reported configuration, "
            "and switch the running system.\n\nContinue?");
        if (answer != QMessageBox::Yes)
            return;

        startService(applyService(), "update");
    }

    void confirmBoot()
    {
        if (!canApply() || serviceBusy())
            return;
        const auto answer = QMessageBox::question(this, "Install for Next Boot?",
            "This will update the real flake.lock and make the verified system the "
            "default for the next boot. It will not switch the running system.\n\nContinue?");
        if (answer != QMessageBox::Yes)
            return;

        startService(bootService(), "boot");
    }

    QString checkerService() const
    {
        return environment("NIXOS_UPDATE_CHECKER_SERVICE", "nixos-update-checker.service");
    }

    QString backgroundService() const
    {
        return environment("NIXOS_UPDATE_CHECKER_BACKGROUND_SERVICE",
            "nixos-update-checker-background.service");
    }

    QString applyService() const
    {
        return environment(
            "NIXOS_UPDATE_CHECKER_APPLY_SERVICE", "nixos-update-checker-apply.service");
    }

    QString bootService() const
    {
        return environment(
            "NIXOS_UPDATE_CHECKER_BOOT_SERVICE", "nixos-update-checker-boot.service");
    }

    QString buildService() const
    {
        return environment("NIXOS_UPDATE_CHECKER_BUILD_SERVICE",
            "nixos-update-checker-build.service");
    }

    QString activeRefreshService() const
    {
        return backgroundRunning_ ? backgroundService() : checkerService();
    }

    void startService(const QString &service, const QString &action)
    {
        if (serviceBusy())
            return;

        activeAction_ = action;
        operationError_.clear();
        operationState_.clear();
        operationMessage_.clear();
        operationDiagnostics_.clear();
        showProgress(true);
        if (action == "refresh")
            appendOutput(QStringLiteral("Starting update preview…\n"));
        else if (action == "build")
            appendOutput(QStringLiteral("Starting reviewed update build…\n"));
        else if (action == "boot")
            appendOutput(QStringLiteral("Installing the verified update for next boot…\n"));
        else
            appendOutput(QStringLiteral("Starting system update…\n"));
        startJournal(service, false);

        auto *process = new QProcess(this);
        activeProcess_ = process;
        process->setProcessChannelMode(QProcess::MergedChannels);
        updatePresentation();
        const QString systemctl = environment("NIXOS_UPDATE_CHECKER_SYSTEMCTL", "systemctl");
        connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                [this, process, service, action](int exitCode, QProcess::ExitStatus) {
                    const QByteArray output = process->readAll();
                    appendOutput(output);
                    if (activeProcess_ == process)
                        activeProcess_ = nullptr;
                    activeAction_.clear();
                    process->deleteLater();
                    if (exitCode == 0) {
                        startGraceUntil_ = QDateTime::currentDateTime().addSecs(3);
                        if (action == "refresh")
                            checkerRunning_ = true;
                        else if (action == "build")
                            buildRunning_ = true;
                        else if (action == "boot")
                            bootRunning_ = true;
                        else
                            applyRunning_ = true;
                        pollServiceState();
                        updatePresentation();
                        return;
                    }
                    stopJournalSoon(service);
                    startGraceUntil_ = {};
                    const QString diagnostics = QString::fromUtf8(output).trimmed();
                    const QString detail = diagnostics.isEmpty()
                        ? "Run journalctl -u " + service + " for details."
                        : diagnostics;
                    operationError_ = "Could not start " + action + ": " + detail;
                    appendOutput("\n" + operationError_ + "\n");
                    QMessageBox::critical(this, "Could not start " + action, detail);
                    updatePresentation();
                });
        connect(process, &QProcess::errorOccurred, this,
                [this, process, service, action](QProcess::ProcessError error) {
                    if (error != QProcess::FailedToStart || activeProcess_ != process)
                        return;
                    activeProcess_ = nullptr;
                    activeAction_.clear();
                    stopJournalSoon(service);
                    operationError_ = "Could not run systemctl: " + process->errorString();
                    appendOutput("\n" + operationError_ + "\n");
                    process->deleteLater();
                    startGraceUntil_ = {};
                    QMessageBox::critical(this, "Could not start " + action, operationError_);
                    updatePresentation();
                });
        process->start(systemctl, {"start", "--no-block", service});
    }

    void cancelService(const QString &service, const QString &action)
    {
        if (activeProcess_ || service.isEmpty())
            return;

        activeAction_ = "cancel-" + action;
        operationError_.clear();
        showProgress(false);
        appendOutput("\nCancelling " + action + "…\n");
        auto *process = new QProcess(this);
        activeProcess_ = process;
        process->setProcessChannelMode(QProcess::MergedChannels);
        updatePresentation();
        const QString systemctl = environment("NIXOS_UPDATE_CHECKER_SYSTEMCTL", "systemctl");
        connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                [this, process, service, action](int exitCode, QProcess::ExitStatus) {
                    const QString output = QString::fromUtf8(process->readAll()).trimmed();
                    if (activeProcess_ == process)
                        activeProcess_ = nullptr;
                    activeAction_.clear();
                    startGraceUntil_ = {};
                    process->deleteLater();
                    if (exitCode != 0) {
                        operationError_ = output.isEmpty()
                            ? "Could not cancel " + action + "."
                            : "Could not cancel " + action + ": " + output;
                        appendOutput(operationError_ + "\n");
                    }
                    pollServiceState();
                    stopJournalSoon(service);
                    updatePresentation();
                });
        connect(process, &QProcess::errorOccurred, this,
                [this, process, action](QProcess::ProcessError error) {
                    if (error != QProcess::FailedToStart || activeProcess_ != process)
                        return;
                    activeProcess_ = nullptr;
                    activeAction_.clear();
                    operationError_ = "Could not cancel " + action + ": " + process->errorString();
                    appendOutput(operationError_ + "\n");
                    process->deleteLater();
                    updatePresentation();
                });
        process->start(systemctl, {"stop", service});
    }

    bool canApply() const
    {
        return schemaSupported_ && analysisMode_ == "verified" && !reportStale_
            && inputBaselineComplete_ && updatesAvailable_;
    }

    bool canBuild() const
    {
        return schemaSupported_ && analysisMode_ == "preview" && !reportStale_
            && updatesAvailable_;
    }

    void updateButtons()
    {
        const bool refreshing = isRefreshing();
        const bool building = isBuilding();
        const bool installing = isUpdating() || isBooting();
        const bool controlling = activeProcess_ != nullptr;

        refreshButton_->setText(refreshing ? "Cancel Refresh" : "Refresh");
        refreshButton_->setEnabled(!controlling && !building && !installing);

        if (building) {
            updateButton_->setText("Cancel Build");
            updateButton_->setEnabled(!controlling && !refreshing && !installing);
        } else {
            updateButton_->setText(analysisMode_ == "preview" ? "Build Update" : "Update Now");
            updateButton_->setEnabled(!controlling && !refreshing && !installing
                && (canBuild() || canApply()));
        }
        bootButton_->setVisible(canApply() || isBooting());
        bootButton_->setEnabled(!controlling && canApply() && !serviceBusy());
        if (trayRefreshAction_)
            trayRefreshAction_->setEnabled(!serviceBusy() && !controlling);
    }

    void addRow(const QString &name, const QString &version, const QString &size,
                const QString &details)
    {
        const int row = updates_->rowCount();
        updates_->insertRow(row);
        auto *nameItem = new QTableWidgetItem(name);
        nameItem->setData(DetailRole, details);
        updates_->setItem(row, 0, nameItem);
        updates_->setItem(row, 1, new QTableWidgetItem(version));
        auto *sizeItem = new QTableWidgetItem(size);
        sizeItem->setTextAlignment(Qt::AlignRight | Qt::AlignVCenter);
        updates_->setItem(row, 2, sizeItem);
    }

    void populate(const QJsonObject &report)
    {
        analysisMode_ = report.value("analysis").toObject().value("mode").toString();
        const QJsonArray inputs = report.value("inputs").toArray();
        const QJsonObject packages = report.value("packages").toObject();
        const QJsonArray changes = packages.value("changes").toArray();
        const QJsonObject rebuilds = packages.value("rebuilds").toObject();
        const int rebuildCount = rebuilds.value("count").toInt();

        updates_->setRowCount(0);
        details_->clear();
        for (const QJsonValue &value : inputs) {
            const QJsonObject change = value.toObject();
            addRow("Input: " + change.value("name").toString(),
                change.value("after").toObject().value("display").toString("missing"),
                "—", inputDetails(change));
        }
        for (const QJsonValue &value : changes) {
            const QJsonObject change = value.toObject();
            const QString size = change.value("sizeKnown").toBool()
                ? formatBytes(change.value("deltaBytes").toInteger(), true)
                : QStringLiteral("—");
            addRow(change.value("name").toString(), versionSummary(change),
                size, packageDetails(change));
        }
        if (rebuildCount > 0) {
            const QString size = rebuilds.value("sizeKnown").toBool()
                ? formatBytes(rebuilds.value("deltaBytes").toInteger(), true)
                : QStringLiteral("—");
            addRow("Rebuilt packages", QString::number(rebuildCount) + " unchanged",
                size, rebuildDetails(rebuilds));
        }
        if (updates_->rowCount() == 0)
            addRow("No updates available", "", "", "");

        const QString text = plural(inputs.size(), "input") + "  ·  "
            + plural(changes.size(), "package change") + "  ·  "
            + plural(rebuildCount, "rebuilt package");
        summaryText_ = text;
        summary_->setText(text);
        updatesAvailable_ = report.value("updatesAvailable").toBool();
        inputBaselineComplete_ = report.value("inputBaseline").toObject().value("complete").toBool();
        schemaSupported_ = true;
        reportStale_ = false;
        reportError_ = false;
        reportErrorMessage_.clear();
        operationError_.clear();

        QString checked = (analysisMode_ == "verified" ? "Verified " : "Previewed ")
            + timestamp(report.value("generatedAt")) + "  ·  "
            + report.value("configuration").toString();
        if (analysisMode_ == "preview")
            checked += "  ·  no candidate build performed";
        if (!inputBaselineComplete_)
            checked += "  ·  partial input history";
        reportStatus_ = checked;
        updatePresentation();
    }

    QString generationFor(const QString &system) const
    {
        if (system.isEmpty())
            return {};
        const QDir directory(environment(
            "NIXOS_UPDATE_CHECKER_PROFILE_DIRECTORY", "/nix/var/nix/profiles"));
        const QDir::Filters filters = QDir::System | QDir::Files | QDir::Dirs
            | QDir::NoDotAndDotDot;
        int highest = -1;
        for (const QString &name : directory.entryList({"system-*-link"}, filters)) {
            if (canonicalPath(directory.filePath(name)) == system) {
                QString number = name;
                number.remove(0, QString("system-").size());
                number.chop(QString("-link").size());
                bool valid = false;
                const int generation = number.toInt(&valid);
                if (valid && generation > highest)
                    highest = generation;
            }
        }
        return highest < 0 ? QString{} : QString::number(highest);
    }

    QString generationName(const QString &system, const QString &fallback) const
    {
        const QString number = generationFor(system);
        return number.isEmpty() ? fallback : "Generation " + number;
    }

    void refreshLiveSystemState()
    {
        const QString liveRunning = canonicalPath(environment(
            "NIXOS_UPDATE_CHECKER_RUNNING_SYSTEM", "/run/current-system"));
        QString liveBoot = canonicalPath(environment(
            "NIXOS_UPDATE_CHECKER_BOOT_SYSTEM", "/nix/var/nix/profiles/system"));
        if (liveBoot.isEmpty())
            liveBoot = liveRunning;

        readyForBoot_ = !liveRunning.isEmpty() && liveBoot != liveRunning;
        if (!liveRunning.isEmpty() && liveBoot != liveRunning) {
            generationStatus_->setText(generationName(liveBoot, "The default boot system")
                + " is ready for next boot; currently running "
                + generationName(liveRunning, "a different system").toLower() + ".");
        } else if (!liveRunning.isEmpty()) {
            generationStatus_->setText("Running "
                + generationName(liveRunning, "the default system").toLower() + ".");
        }

        if (!schemaSupported_ || lastReport_.isEmpty()
            || lastReport_.value("status").toString() != "success") {
            updatePresentation();
            return;
        }
        const QString expectedBaseline = liveBoot != liveRunning ? liveBoot : liveRunning;
        const QString reportBaseline = lastReport_.value("system").toObject()
                                           .value("baselinePath").toString();
        if (!expectedBaseline.isEmpty() && expectedBaseline != reportBaseline) {
            markReportStale("The system profile changed. Waiting for a new background report.");
        } else if (reportStale_) {
            populate(lastReport_);
        }
        updatePresentation();
    }

    void loadReport(bool initial)
    {
        const QFileInfo info(reportPath_);
        if (!info.exists()) {
            if (initial) {
                reportStatus_ = "No report yet. Select Refresh to start the service.";
                summary_->setText("No report yet");
                updatePresentation();
            }
            return;
        }
        if (!initial && info.lastModified() == reportMtime_)
            return;

        QFile file(reportPath_);
        if (!file.open(QIODevice::ReadOnly)) {
            reportStatus_ = "The report is not readable";
            updatePresentation();
            return;
        }
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            reportStatus_ = "The service wrote an invalid report";
            updatePresentation();
            return;
        }

        const QJsonObject report = document.object();
        reportMtime_ = info.lastModified();
        lastReport_ = report;
        if (report.value("schemaVersion").toInt() != 3) {
            schemaSupported_ = false;
            analysisMode_.clear();
            updatesAvailable_ = false;
            inputBaselineComplete_ = false;
            updates_->setRowCount(0);
            details_->clear();
            summary_->setText("Report needs refreshing");
            reportStatus_ = "Select Refresh to replace the cached report.";
            reportError_ = false;
            updatePresentation();
            return;
        }
        if (report.value("status").toString() == "error") {
            const QJsonObject error = report.value("error").toObject();
            schemaSupported_ = true;
            analysisMode_ = report.value("analysis").toObject().value("mode").toString();
            updatesAvailable_ = false;
            inputBaselineComplete_ = false;
            summary_->setText("Check failed");
            reportErrorMessage_ = error.value("message").toString("Background check failed");
            reportStatus_ = reportErrorMessage_;
            reportError_ = true;
            const QString diagnostics = error.value("diagnostics").toString();
            appendOutput("\n" + diagnostics + "\n");
            updates_->setRowCount(0);
            updatePresentation();
            return;
        }
        populate(report);
    }

    void loadOperationStatus(bool initial)
    {
        const QFileInfo info(statusPath_);
        if (!info.exists() || (!initial && info.lastModified() == statusMtime_))
            return;

        QFile file(statusPath_);
        if (!file.open(QIODevice::ReadOnly))
            return;
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject())
            return;

        const QJsonObject status = document.object();
        if (status.value("schemaVersion").toInt() != 1)
            return;
        statusMtime_ = info.lastModified();
        operationState_ = status.value("state").toString();
        operationMessage_ = status.value("message").toString();
        operationDiagnostics_ = status.value("diagnostics").toString();
        if (operationState_ == "failed" || operationState_ == "cancelled") {
            if (!operationMessage_.isEmpty())
                appendOutput("\n" + operationMessage_ + "\n");
            if (!operationDiagnostics_.isEmpty())
                appendOutput(operationDiagnostics_ + "\n");
        }
        updatePresentation();
    }

    void markReportStale(const QString &message)
    {
        reportStale_ = true;
        reportError_ = false;
        summary_->setText("Report is stale");
        reportStatus_ = message;
    }

    bool isRefreshing() const
    {
        return checkerRunning_ || backgroundRunning_
            || (activeProcess_ && activeAction_ == "refresh");
    }

    bool isUpdating() const
    {
        return applyRunning_ || (activeProcess_ && activeAction_ == "update");
    }

    bool isBooting() const
    {
        return bootRunning_ || (activeProcess_ && activeAction_ == "boot");
    }

    bool isBuilding() const
    {
        return buildRunning_ || (activeProcess_ && activeAction_ == "build");
    }

    bool serviceBusy() const
    {
        return isRefreshing() || isBuilding() || isUpdating() || isBooting();
    }

    void appendOutput(const QByteArray &data)
    {
        appendOutput(QString::fromUtf8(data));
    }

    void appendOutput(const QString &text)
    {
        if (text.isEmpty())
            return;
        QTextCursor cursor = progress_->textCursor();
        cursor.movePosition(QTextCursor::End);
        cursor.insertText(text);
        progress_->setTextCursor(cursor);
        progress_->verticalScrollBar()->setValue(progress_->verticalScrollBar()->maximum());
    }

    void showProgress(bool clear)
    {
        if (clear)
            progress_->clear();
        infoTabs_->setCurrentWidget(progress_);
    }

    void startJournal(const QString &service, bool clear)
    {
        if (journalProcess_ && journalService_ == service)
            return;
        stopJournal();
        if (clear)
            progress_->clear();
        journalService_ = service;

        auto *process = new QProcess(this);
        journalProcess_ = process;
        process->setProcessChannelMode(QProcess::MergedChannels);
        connect(process, &QProcess::readyRead, this,
                [this, process] { appendOutput(process->readAll()); });
        connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                [this, process](int, QProcess::ExitStatus) {
                    appendOutput(process->readAll());
                    if (journalProcess_ == process) {
                        journalProcess_ = nullptr;
                        journalService_.clear();
                    }
                    process->deleteLater();
                });
        connect(process, &QProcess::errorOccurred, this,
                [this, process](QProcess::ProcessError error) {
                    if (error != QProcess::FailedToStart || journalProcess_ != process)
                        return;
                    journalProcess_ = nullptr;
                    journalService_.clear();
                    appendOutput("Could not follow the system journal: " + process->errorString() + "\n");
                    process->deleteLater();
                });
        const QString journalctl = environment("NIXOS_UPDATE_CHECKER_JOURNALCTL", "journalctl");
        process->start(journalctl,
            {"--follow", "--unit", service, "--output=cat", "--since=-10s", "--no-pager"});
    }

    void stopJournal()
    {
        if (!journalProcess_)
            return;
        QProcess *process = journalProcess_;
        journalProcess_ = nullptr;
        journalService_.clear();
        process->terminate();
        QTimer::singleShot(500, process, [process] {
            if (process->state() != QProcess::NotRunning)
                process->kill();
        });
    }

    void stopJournalSoon(const QString &service)
    {
        QTimer::singleShot(250, this, [this, service] {
            if (journalService_ == service)
                stopJournal();
        });
    }

    void pollServiceState()
    {
        if (stateProcess_)
            return;
        auto *process = new QProcess(this);
        stateProcess_ = process;
        connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                [this, process](int, QProcess::ExitStatus) {
                    const QString output = QString::fromUtf8(process->readAllStandardOutput());
                    if (stateProcess_ == process)
                        stateProcess_ = nullptr;
                    process->deleteLater();

                    bool checkerSeen = false;
                    bool backgroundSeen = false;
                    bool buildSeen = false;
                    bool applySeen = false;
                    bool bootSeen = false;
                    bool checkerActive = false;
                    bool backgroundActive = false;
                    bool buildActive = false;
                    bool applyActive = false;
                    bool bootActive = false;
                    for (const QString &block : output.split("\n\n", Qt::SkipEmptyParts)) {
                        QString id;
                        QString active;
                        for (const QString &line : block.split('\n')) {
                            if (line.startsWith("Id="))
                                id = line.mid(3).trimmed();
                            else if (line.startsWith("ActiveState="))
                                active = line.mid(12).trimmed();
                        }
                        const bool running = active == "active" || active == "activating"
                            || active == "reloading";
                        if (id == checkerService()) {
                            checkerSeen = true;
                            checkerActive = running;
                        } else if (id == backgroundService()) {
                            backgroundSeen = true;
                            backgroundActive = running;
                        } else if (id == buildService()) {
                            buildSeen = true;
                            buildActive = running;
                        } else if (id == applyService()) {
                            applySeen = true;
                            applyActive = running;
                        } else if (id == bootService()) {
                            bootSeen = true;
                            bootActive = running;
                        }
                    }
                    if (checkerSeen || backgroundSeen || buildSeen || applySeen || bootSeen)
                        setServiceActivity(checkerSeen ? checkerActive : checkerRunning_,
                            backgroundSeen ? backgroundActive : backgroundRunning_,
                            buildSeen ? buildActive : buildRunning_,
                            applySeen ? applyActive : applyRunning_,
                            bootSeen ? bootActive : bootRunning_);
                });
        connect(process, &QProcess::errorOccurred, this,
                [this, process](QProcess::ProcessError error) {
                    if (error != QProcess::FailedToStart || stateProcess_ != process)
                        return;
                    stateProcess_ = nullptr;
                    process->deleteLater();
                });
        const QString systemctl = environment("NIXOS_UPDATE_CHECKER_SYSTEMCTL", "systemctl");
        process->start(systemctl,
            {"show", "--property=Id", "--property=ActiveState", "--property=SubState",
                checkerService(), backgroundService(), buildService(), applyService(),
                bootService()});
    }

    void setServiceActivity(
        bool checkerActive, bool backgroundActive, bool buildActive, bool applyActive,
        bool bootActive)
    {
        if (QDateTime::currentDateTime() < startGraceUntil_) {
            checkerActive = checkerActive || checkerRunning_;
            backgroundActive = backgroundActive || backgroundRunning_;
            buildActive = buildActive || buildRunning_;
            applyActive = applyActive || applyRunning_;
            bootActive = bootActive || bootRunning_;
        }
        const bool checkerFinished = checkerRunning_ && !checkerActive;
        const bool backgroundFinished = backgroundRunning_ && !backgroundActive;
        const bool buildFinished = buildRunning_ && !buildActive;
        const bool applyFinished = applyRunning_ && !applyActive;
        const bool bootFinished = bootRunning_ && !bootActive;
        checkerRunning_ = checkerActive;
        backgroundRunning_ = backgroundActive;
        buildRunning_ = buildActive;
        applyRunning_ = applyActive;
        bootRunning_ = bootActive;

        if (applyRunning_) {
            if (journalService_ != applyService()) {
                progress_->clear();
                appendOutput(QStringLiteral("System update in progress…\n"));
                startJournal(applyService(), false);
            }
        } else if (bootRunning_) {
            if (journalService_ != bootService()) {
                progress_->clear();
                appendOutput(QStringLiteral("Installing update for next boot…\n"));
                startJournal(bootService(), false);
            }
        } else if (buildRunning_) {
            if (journalService_ != buildService()) {
                progress_->clear();
                appendOutput(QStringLiteral("Reviewed update build in progress…\n"));
                startJournal(buildService(), false);
            }
        } else if (checkerRunning_) {
            if (journalService_ != checkerService()) {
                progress_->clear();
                appendOutput(QStringLiteral("Update check in progress…\n"));
                startJournal(checkerService(), false);
            }
        } else if (backgroundRunning_) {
            if (journalService_ != backgroundService()) {
                progress_->clear();
                appendOutput(QStringLiteral("Automatic update check in progress…\n"));
                startJournal(backgroundService(), false);
            }
        } else if (checkerFinished || backgroundFinished || buildFinished || applyFinished
            || bootFinished) {
            stopJournalSoon(journalService_);
            loadReport(true);
            loadOperationStatus(true);
            refreshLiveSystemState();
            if (applyFinished && !activeProcess_) {
                markReportStale("The update finished. Waiting for the refreshed report.");
                checkForReplacement();
                updatePresentation();
                return;
            }
            if (bootFinished) {
                markReportStale("The update is installed and ready for the next boot.");
                refreshLiveSystemState();
            }
        }
        updatePresentation();
    }

    void updatePresentation()
    {
        QString busyText;
        if (isUpdating()) {
            busyText = "Updating…";
            status_->setText("Updating the system…");
        } else if (isBooting()) {
            busyText = "Installing…";
            status_->setText("Installing the update for next boot…");
        } else if (isBuilding()) {
            busyText = "Building…";
            status_->setText("Building and verifying the reviewed update…");
        } else if (isRefreshing()) {
            busyText = "Refreshing…";
            status_->setText("Refreshing the update report…");
        } else if (!operationError_.isEmpty()) {
            status_->setText(operationError_);
        } else if (operationState_ == "failed") {
            status_->setText(operationMessage_.isEmpty() ? "The last operation failed."
                                                         : operationMessage_);
        } else if (operationState_ == "cancelled") {
            status_->setText(operationMessage_.isEmpty() ? "The operation was cancelled."
                                                         : operationMessage_);
        } else {
            status_->setText(reportStatus_);
        }
        updates_->setBusy(!busyText.isEmpty(), busyText);
        updateButtons();
        updateTray();
    }

    void updateTray()
    {
        if (!tray_)
            return;

        QString iconName = "system-software-update";
        QString message = "No update report is available";
        if (isUpdating()) {
            iconName = "system-software-update";
            message = "Updating the system…";
        } else if (isBooting()) {
            iconName = "system-reboot";
            message = "Installing the update for next boot…";
        } else if (isBuilding()) {
            iconName = "view-refresh";
            message = "Building and verifying the reviewed update…";
        } else if (isRefreshing()) {
            iconName = "view-refresh";
            message = "Refreshing the update report…";
        } else if (restartBanner_->isVisible()) {
            iconName = "software-update-available";
            message = "A new updater is installed; open the window to restart";
        } else if (readyForBoot_) {
            iconName = "system-reboot";
            message = generationStatus_->text();
            if (schemaSupported_ && updatesAvailable_)
                message += "\nRemaining beyond next boot: " + summaryText_;
        } else if (operationState_ == "failed") {
            iconName = "dialog-error";
            message = operationMessage_.isEmpty() ? "The last operation failed"
                                                   : operationMessage_;
        } else if (reportStale_) {
            iconName = "dialog-warning";
            message = "The report is stale; waiting for a refresh";
        } else if (reportError_) {
            iconName = "dialog-error";
            message = "Last check failed: " + reportErrorMessage_;
        } else if (schemaSupported_ && updatesAvailable_) {
            iconName = "software-update-available";
            message = summaryText_;
            if (analysisMode_ == "preview")
                message += " (preview; build to verify)";
        } else if (schemaSupported_) {
            iconName = "emblem-default";
            message = "System is up to date";
        }
        tray_->setIcon(QIcon::fromTheme(iconName, applicationIcon()));
        tray_->setToolTip("NixOS Update Checker\n" + message);
    }

    void restartApplication()
    {
        const QString executable = environment("NIXOS_UPDATE_CHECKER_INSTALLED_EXECUTABLE",
            "/run/current-system/sw/bin/nixos-update-checker");
        if (!QFileInfo(executable).isExecutable())
            return;
        QStringList arguments = QCoreApplication::arguments();
        if (!arguments.isEmpty())
            arguments.removeFirst();
        const bool windowWasVisible = isVisible();
        if (tray_)
            tray_->hide();
        hide();
        QApplication::processEvents();
        if (!QProcess::startDetached(executable, arguments)) {
            operationError_ = "The new application could not start.";
            if (tray_)
                tray_->show();
            if (windowWasVisible)
                showAndRaise();
            updatePresentation();
            return;
        }
        quitRequested_ = true;
        QApplication::quit();
    }

    void checkForReplacement()
    {
        const QString executable = environment("NIXOS_UPDATE_CHECKER_INSTALLED_EXECUTABLE",
            "/run/current-system/sw/bin/nixos-update-checker");
        const QString installedPackage = nixStorePackage(executable);
        const bool replacementAvailable = !runningPackage_.isEmpty()
            && !installedPackage.isEmpty() && runningPackage_ != installedPackage;
        if (restartBanner_->isVisible() != replacementAvailable) {
            restartBanner_->setVisible(replacementAvailable);
            updateTray();
        }
    }

    QString reportPath_;
    QString statusPath_;
    QString runningPackage_;
    bool trayEnabled_ = true;
    bool quitRequested_ = false;
    bool schemaSupported_ = false;
    bool reportStale_ = false;
    bool inputBaselineComplete_ = false;
    bool updatesAvailable_ = false;
    bool reportError_ = false;
    bool checkerRunning_ = false;
    bool backgroundRunning_ = false;
    bool buildRunning_ = false;
    bool applyRunning_ = false;
    bool bootRunning_ = false;
    bool readyForBoot_ = false;
    QString summaryText_;
    QString analysisMode_;
    QString reportStatus_ = "Waiting for a report";
    QString reportErrorMessage_;
    QString operationError_;
    QString operationState_;
    QString operationMessage_;
    QString operationDiagnostics_;
    QString activeAction_;
    QString journalService_;
    QDateTime reportMtime_;
    QDateTime statusMtime_;
    QDateTime startGraceUntil_;
    QJsonObject lastReport_;
    QTimer pollTimer_;
    QProcess *activeProcess_ = nullptr;
    QProcess *stateProcess_ = nullptr;
    QProcess *journalProcess_ = nullptr;
    QSystemTrayIcon *tray_ = nullptr;
    QAction *trayRefreshAction_ = nullptr;
    QFrame *restartBanner_ = nullptr;
    QLabel *summary_ = nullptr;
    QLabel *generationStatus_ = nullptr;
    QLabel *status_ = nullptr;
    UpdateTable *updates_ = nullptr;
    QTabWidget *infoTabs_ = nullptr;
    QPlainTextEdit *details_ = nullptr;
    QPlainTextEdit *progress_ = nullptr;
    QPushButton *refreshButton_ = nullptr;
    QPushButton *restartButton_ = nullptr;
    QPushButton *bootButton_ = nullptr;
    QPushButton *updateButton_ = nullptr;
};

} // namespace

int main(int argc, char **argv)
{
    QApplication application(argc, argv);
    application.setApplicationName("nixos-update-checker");
    application.setApplicationDisplayName("NixOS Update Checker");
    application.setApplicationVersion(Version);

    QCommandLineParser parser;
    parser.setApplicationDescription("Display the latest NixOS update report");
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption reportOption("report", "Read reports from PATH.", "PATH",
        QString{});
    QCommandLineOption noTrayOption("no-tray", "Do not create a system tray icon.");
    parser.addOption(reportOption);
    parser.addOption(noTrayOption);
    parser.process(application);

    const AppSettings settings = loadSettings();
    QString reportPath = parser.isSet(reportOption) ? parser.value(reportOption) : settings.reportPath;
    if (reportPath.isEmpty())
        reportPath = environment(
            "NIXOS_UPDATE_CHECKER_REPORT", "/var/lib/nixos-update-checker/report.json");
    const bool trayEnabled = settings.trayEnabled && !parser.isSet(noTrayOption);
    application.setQuitOnLastWindowClosed(!trayEnabled);
    MainWindow window(reportPath, trayEnabled);
    window.show();
    return application.exec();
}
