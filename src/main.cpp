#include <QAbstractItemView>
#include <QApplication>
#include <QCloseEvent>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
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
#include <QPlainTextEdit>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QSplitter>
#include <QStyle>
#include <QSystemTrayIcon>
#include <QTableWidget>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>

namespace {

constexpr auto Version = "3.1.1";
constexpr int DetailRole = Qt::UserRole;

QString environment(const char *name, const QString &fallback = {})
{
    const QString value = qEnvironmentVariable(name);
    return value.isEmpty() ? fallback : value;
}

QString canonicalPath(const QString &path)
{
    return QFileInfo(path).canonicalFilePath();
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
        "Flake input: " + change.value("name").toString(),
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
        "Net closure change: " + formatBytes(change.value("deltaBytes").toInteger(), true),
        "Added to candidate closure: " + formatBytes(change.value("addedBytes").toInteger()),
        "No longer referenced by candidate: " + formatBytes(change.value("removedBytes").toInteger()),
    };
    if (after.isObject())
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
        "Net closure change: " + formatBytes(rebuilds.value("deltaBytes").toInteger(), true),
        "Added to candidate closure: " + formatBytes(rebuilds.value("addedBytes").toInteger()),
        "No longer referenced by candidate: " + formatBytes(rebuilds.value("removedBytes").toInteger()),
        "",
    };
    for (const QJsonValue &value : rebuilds.value("items").toArray()) {
        const QJsonObject item = value.toObject();
        QStringList itemVersions;
        for (const QJsonValue &version : item.value("versions").toArray())
            itemVersions << version.toString();
        lines << item.value("name").toString() + " — " + itemVersions.join(", ");
    }
    return lines.join('\n');
}

class MainWindow final : public QMainWindow
{
public:
    MainWindow(QString reportPath, bool trayEnabled)
        : reportPath_(std::move(reportPath)), trayEnabled_(trayEnabled)
    {
        setWindowTitle("NixOS Update Checker");
        resize(840, 650);
        setMinimumSize(640, 440);
        buildInterface();
        buildTray();

        connect(&pollTimer_, &QTimer::timeout, this, [this] {
            loadReport(false);
            refreshLiveSystemState();
        });
        pollTimer_.start(3000);
        loadReport(true);
        refreshLiveSystemState();
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

        summary_ = new QLabel("No report yet", central);
        QFont summaryFont = summary_->font();
        summaryFont.setPointSize(summaryFont.pointSize() + 3);
        summaryFont.setBold(true);
        summary_->setFont(summaryFont);
        layout->addWidget(summary_);

        generationStatus_ = new QLabel(central);
        generationStatus_->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(generationStatus_);

        auto *splitter = new QSplitter(Qt::Vertical, central);
        splitter->setChildrenCollapsible(false);
        updates_ = new QTableWidget(0, 3, splitter);
        updates_->setHorizontalHeaderLabels({"Package", "New version", "Size"});
        updates_->setAlternatingRowColors(false);
        updates_->setEditTriggers(QAbstractItemView::NoEditTriggers);
        updates_->setSelectionBehavior(QAbstractItemView::SelectRows);
        updates_->setSelectionMode(QAbstractItemView::SingleSelection);
        updates_->setTextElideMode(Qt::ElideRight);
        updates_->verticalHeader()->hide();
        updates_->verticalHeader()->setDefaultSectionSize(40);
        updates_->horizontalHeader()->setSectionsMovable(false);
        updates_->horizontalHeader()->setSectionsClickable(false);
        updates_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
        updates_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Fixed);
        updates_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Fixed);
        updates_->setColumnWidth(1, 190);
        updates_->setColumnWidth(2, 110);

        details_ = new QPlainTextEdit(splitter);
        details_->setReadOnly(true);
        details_->setPlaceholderText("Select an update to see its details.");
        splitter->addWidget(updates_);
        splitter->addWidget(details_);
        splitter->setStretchFactor(0, 3);
        splitter->setStretchFactor(1, 1);
        splitter->setSizes({460, 150});
        layout->addWidget(splitter, 1);

        auto *footer = new QHBoxLayout;
        status_ = new QLabel("Waiting for a report", central);
        status_->setTextInteractionFlags(Qt::TextSelectableByMouse);
        progress_ = new QProgressBar(central);
        progress_->setRange(0, 0);
        progress_->setTextVisible(false);
        progress_->setFixedWidth(90);
        progress_->hide();
        applyButton_ = new QPushButton("Apply update", central);
        checkButton_ = new QPushButton("Check now", central);
        footer->addWidget(status_, 1);
        footer->addWidget(progress_);
        footer->addWidget(applyButton_);
        footer->addWidget(checkButton_);
        layout->addLayout(footer);
        setCentralWidget(central);

        connect(updates_, &QTableWidget::currentCellChanged, this,
                [this](int row, int, int, int) {
                    const QTableWidgetItem *item = row >= 0 ? updates_->item(row, 0) : nullptr;
                    details_->setPlainText(item ? item->data(DetailRole).toString() : QString{});
                });
        connect(checkButton_, &QPushButton::clicked, this, [this] { startCheck(); });
        connect(applyButton_, &QPushButton::clicked, this, [this] { confirmApply(); });
        updateButtons();
    }

    QIcon applicationIcon() const
    {
        const QString path = environment("NIXOS_UPDATE_CHECKER_ICON");
        if (!path.isEmpty() && QFileInfo::exists(path))
            return QIcon(path);
        return style()->standardIcon(QStyle::SP_ComputerIcon);
    }

    void buildTray()
    {
        setWindowIcon(applicationIcon());
        if (!trayEnabled_)
            return;

        tray_ = new QSystemTrayIcon(applicationIcon(), this);
        auto *menu = new QMenu(this);
        auto *showAction = menu->addAction("Show");
        auto *checkAction = menu->addAction("Check now");
        menu->addSeparator();
        auto *quitAction = menu->addAction("Quit");
        connect(showAction, &QAction::triggered, this, [this] { showAndRaise(); });
        connect(checkAction, &QAction::triggered, this, [this] { startCheck(); });
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
        const QString service = environment("NIXOS_UPDATE_CHECKER_SERVICE", "nixos-update-checker.service");
        startService(service, "check", "Check finished.");
    }

    void confirmApply()
    {
        if (!canApply() || activeProcess_)
            return;
        const auto answer = QMessageBox::question(this, "Apply NixOS update?",
            "This will update the real flake.lock, rebuild the reported configuration, "
            "and switch the running system.\n\nContinue?");
        if (answer != QMessageBox::Yes)
            return;

        const QString service = environment(
            "NIXOS_UPDATE_CHECKER_APPLY_SERVICE", "nixos-update-checker-apply.service");
        startService(service, "update", "Update finished.");
    }

    void startService(const QString &service, const QString &action, const QString &completedMessage)
    {
        if (activeProcess_)
            return;

        status_->setText("Requesting " + action + "…");
        activeProcess_ = new QProcess(this);
        progress_->show();
        updateButtons();
        const QString systemctl = environment("NIXOS_UPDATE_CHECKER_SYSTEMCTL", "systemctl");
        connect(activeProcess_, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
                [this, service, action, completedMessage](int exitCode, QProcess::ExitStatus) {
                    const QString diagnostics = QString::fromUtf8(activeProcess_->readAllStandardError()).trimmed();
                    activeProcess_->deleteLater();
                    activeProcess_ = nullptr;
                    progress_->hide();
                    updateButtons();
                    if (exitCode == 0) {
                        status_->setText(completedMessage);
                        loadReport(false);
                        refreshLiveSystemState();
                        return;
                    }
                    const QString detail = diagnostics.isEmpty()
                        ? "Run journalctl -u " + service + " for details."
                        : diagnostics;
                    QMessageBox::critical(this, "Could not start " + action, detail);
                    status_->setText("Could not start the " + action + " service");
                });
        connect(activeProcess_, &QProcess::started, this,
                [this, action] { status_->setText(action.left(1).toUpper() + action.mid(1) + " running…"); });
        activeProcess_->start(systemctl, {"start", service});
    }

    bool canApply() const
    {
        return schemaSupported_ && !reportStale_ && inputBaselineComplete_ && updatesAvailable_;
    }

    void updateButtons()
    {
        checkButton_->setEnabled(activeProcess_ == nullptr);
        applyButton_->setEnabled(activeProcess_ == nullptr && canApply());
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
        const QJsonArray inputs = report.value("inputs").toArray();
        const QJsonObject packages = report.value("packages").toObject();
        const QJsonArray changes = packages.value("changes").toArray();
        const QJsonObject rebuilds = packages.value("rebuilds").toObject();
        const int rebuildCount = rebuilds.value("count").toInt();

        updates_->setRowCount(0);
        details_->clear();
        for (const QJsonValue &value : inputs) {
            const QJsonObject change = value.toObject();
            addRow("Flake: " + change.value("name").toString(),
                change.value("after").toObject().value("display").toString("missing"),
                "—", inputDetails(change));
        }
        for (const QJsonValue &value : changes) {
            const QJsonObject change = value.toObject();
            addRow(change.value("name").toString(), versionSummary(change),
                formatBytes(change.value("deltaBytes").toInteger(), true),
                packageDetails(change));
        }
        if (rebuildCount > 0) {
            addRow("Rebuilt packages", QString::number(rebuildCount) + " unchanged",
                formatBytes(rebuilds.value("deltaBytes").toInteger(), true),
                rebuildDetails(rebuilds));
        }
        if (updates_->rowCount() == 0)
            addRow("No updates available", "", "", "");

        const QString text = plural(inputs.size(), "flake input") + "  ·  "
            + plural(changes.size(), "package change") + "  ·  "
            + plural(rebuildCount, "rebuilt package");
        summary_->setText(text);
        updatesAvailable_ = report.value("updatesAvailable").toBool();
        inputBaselineComplete_ = report.value("inputBaseline").toObject().value("complete").toBool();
        schemaSupported_ = true;
        reportStale_ = false;
        updateButtons();

        QString checked = "Checked " + timestamp(report.value("generatedAt")) + "  ·  "
            + report.value("configuration").toString();
        if (!inputBaselineComplete_)
            checked += "  ·  partial flake history";
        status_->setText(checked);
        if (tray_)
            tray_->setToolTip("NixOS Update Checker · " + text);
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
            updateButtons();
            return;
        }
        const QString expectedBaseline = liveBoot != liveRunning ? liveBoot : liveRunning;
        const QString reportBaseline = lastReport_.value("system").toObject()
                                           .value("baselinePath").toString();
        if (!expectedBaseline.isEmpty() && expectedBaseline != reportBaseline) {
            reportStale_ = true;
            updates_->setRowCount(0);
            details_->clear();
            summary_->setText("Report is stale");
            status_->setText("The system profile changed. Waiting for a new background report.");
        } else if (reportStale_) {
            populate(lastReport_);
        }
        updateButtons();
    }

    void loadReport(bool initial)
    {
        const QFileInfo info(reportPath_);
        if (!info.exists()) {
            if (initial)
                status_->setText("No report yet. Select Check now to start the service.");
            return;
        }
        if (!initial && info.lastModified() == reportMtime_)
            return;

        QFile file(reportPath_);
        if (!file.open(QIODevice::ReadOnly)) {
            status_->setText("The report is not readable");
            return;
        }
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            status_->setText("The service wrote an invalid report");
            return;
        }

        const QJsonObject report = document.object();
        reportMtime_ = info.lastModified();
        lastReport_ = report;
        if (report.value("schemaVersion").toInt() != 2) {
            schemaSupported_ = false;
            updatesAvailable_ = false;
            inputBaselineComplete_ = false;
            updates_->setRowCount(0);
            details_->clear();
            summary_->setText("Report needs refreshing");
            status_->setText("Run Check now to replace the cached version-1 report.");
            updateButtons();
            return;
        }
        if (report.value("status").toString() == "error") {
            const QJsonObject error = report.value("error").toObject();
            schemaSupported_ = true;
            updatesAvailable_ = false;
            inputBaselineComplete_ = false;
            summary_->setText("Check failed");
            status_->setText(error.value("message").toString("Background check failed"));
            details_->setPlainText(error.value("diagnostics").toString());
            updates_->setRowCount(0);
            updateButtons();
            return;
        }
        populate(report);
    }

    QString reportPath_;
    bool trayEnabled_ = true;
    bool quitRequested_ = false;
    bool schemaSupported_ = false;
    bool reportStale_ = false;
    bool inputBaselineComplete_ = false;
    bool updatesAvailable_ = false;
    QDateTime reportMtime_;
    QJsonObject lastReport_;
    QTimer pollTimer_;
    QProcess *activeProcess_ = nullptr;
    QSystemTrayIcon *tray_ = nullptr;
    QLabel *summary_ = nullptr;
    QLabel *generationStatus_ = nullptr;
    QLabel *status_ = nullptr;
    QTableWidget *updates_ = nullptr;
    QPlainTextEdit *details_ = nullptr;
    QProgressBar *progress_ = nullptr;
    QPushButton *applyButton_ = nullptr;
    QPushButton *checkButton_ = nullptr;
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
        environment("NIXOS_UPDATE_CHECKER_REPORT", "/var/lib/nixos-update-checker/report.json"));
    QCommandLineOption noTrayOption("no-tray", "Do not create a system tray icon.");
    parser.addOption(reportOption);
    parser.addOption(noTrayOption);
    parser.process(application);

    const bool trayEnabled = !parser.isSet(noTrayOption);
    application.setQuitOnLastWindowClosed(!trayEnabled);
    MainWindow window(parser.value(reportOption), trayEnabled);
    window.show();
    return application.exec();
}
