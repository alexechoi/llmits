import AppKit
import OSLog
import ServiceManagement
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sources: [any UsageSource] = [ClaudeSource(), ChatGPTSource()]
    /// What's known about each service, and the rules for what to fetch and show. Tested in UsageCore.
    private var tracker = UsageTracker()
    private var isRefreshing = false
    private var isMenuOpen = false

    /// Every menu item is kept and updated in place. An open menu's item list is only replaced
    /// when its structure changes, so it never jumps or loses the highlight under the pointer.
    private var reusableItems: [String: NSMenuItem] = [:]
    private lazy var refreshItem = actionItem("Refresh", #selector(refreshNow), key: "r")
    private lazy var launchAtLoginItem = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
    private lazy var quitItem: NSMenuItem = {
        let item = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }()

    private var lastButton: ButtonContent?
    /// Asking ServiceManagement is a cross-process call, so it's checked once per menu opening.
    private var launchesAtLogin = false
    /// One line per check, with no secrets: `log show --predicate 'subsystem == "<bundle id>"' --info`.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LLMits", category: "usage")

    /// Where the last numbers are kept between launches (usage and times only).
    private static let savedUsageKey = "savedUsage"
    /// Whether the person turned on Launch at Login here, so it can be restored after an update.
    private static let launchAtLoginKey = "launchAtLogin"

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LLMits"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remember the item's position, and let people ⌘-drag it out of the menu bar to remove
        // it (which quits the app): it's their choice whether it lives there, not the app's.
        statusItem.autosaveName = "LLMits"
        statusItem.behavior = .terminationOnRemoval
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        // Start from the last numbers, so a relaunch never shows a blank menu bar.
        if let data = UserDefaults.standard.data(forKey: Self.savedUsageKey),
           let snapshot = UsageTracker.Snapshot.decode(data) {
            tracker.restore(snapshot)
        }
        render()
        restoreLaunchAtLogin()

        Task {
            while !Task.isCancelled {
                await refresh(force: false)
                // Between 5 seconds and an hour, whatever the clock or a server says; waking from
                // sleep, opening the menu and Refresh all check sooner anyway.
                let wait = tracker.nextWake(after: .now).timeIntervalSinceNow
                let seconds = wait.isFinite ? min(max(wait, 5), 3600) : UsageTracker.pollInterval
                // The tolerance lets macOS batch this wake-up with others to save energy.
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(10))
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        // Region, clock and time zone changes all affect how times are written.
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Format.clearCaches()
                    self?.render()
                }
            }
        }
    }

    // MARK: - Fetching

    /// Fetches every service that's due, or all of them when `force` is set (except any that
    /// asked to be left alone after rate limiting), concurrently.
    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        let now = Date.now
        let due = tracker.servicesToFetch(from: sources.map(\.service), force: force, now: now)
        guard !due.isEmpty else { return }

        isRefreshing = true
        render()  // shows "Updating…"
        await withTaskGroup(of: (Service, FetchOutcome).self) { group in
            for source in sources where due.contains(source.service) {
                group.addTask { (source.service, await source.fetch(now: now)) }
            }
            // Each result shows as soon as it arrives, so one slow service never holds up another.
            for await (service, outcome) in group {
                tracker.record(outcome, for: service, at: .now)
                record(outcome, for: service)
                switch outcome {
                case .success, .notSignedIn:
                    UserDefaults.standard.set(tracker.snapshot.encoded(), forKey: Self.savedUsageKey)
                default:
                    break
                }
                render()
            }
        }
        isRefreshing = false
        render()
        releaseFreedMemory()
    }

    private func record(_ outcome: FetchOutcome, for service: Service) {
        let name = service.name
        switch outcome {
        case let .success(usage):
            log.info("\(name, privacy: .public): updated, \(usage.rows.count) limits")
        case .tokenExpired:
            log.notice("\(name, privacy: .public): login expired")
        case .notSignedIn:
            log.notice("\(name, privacy: .public): not signed in")
        case let .rateLimited(retryAfter):
            log.notice("\(name, privacy: .public): rate limited, retry after \(retryAfter ?? -1, privacy: .public)s")
        case let .failed(failure):
            log.error("\(name, privacy: .public): failed, \(String(describing: failure), privacy: .public)")
        }
    }

    // MARK: - Rendering

    private func render() {
        let now = Date.now
        updateButton(tracker.headline(at: now), now: now)
        if isMenuOpen {
            updateMenu(now: now)
        }
    }

    private struct ButtonContent: Equatable {
        var fraction: Double
        var severity: Severity
        var title: String
    }

    private func updateButton(_ headline: UsageTracker.Headline?, now: Date) {
        guard let button = statusItem.button else { return }
        let severity = headline?.row.severity ?? .normal
        let content = ButtonContent(
            // Whole percents are plenty for a 16pt ring, and mean a redraw only when the number moves.
            fraction: ((headline?.row.percent ?? 0).rounded(.down)) / 100,
            severity: severity,
            title: Format.percent(headline?.row.percent)
        )
        if content != lastButton {
            // Colour goes on the icon only, never the text, so the percentage keeps the menu bar's
            // own contrast on any wallpaper. It stays even when the numbers are old: usage only
            // rises within a window, so an old reading is never worse than the truth.
            button.image = StatusIcon.image(fraction: content.fraction, severity: severity, tint: severity.statusBarColor)
            button.title = content.title
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            lastButton = content
        }
        button.appearsDisabled = headline?.isStale ?? true

        button.setAccessibilityLabel("Usage limits")
        guard let headline else {
            button.setAccessibilityValue(tracker.isLoading ? "Loading" : "No data")
            button.toolTip = appName
            return
        }
        let spoken = Format.spokenValue(headline.row, stale: headline.isStale, now: now)
        button.setAccessibilityValue("\(headline.service.name), \(Format.spokenTitle(headline.row)): \(spoken)")
        let caption = Format.caption(headline.row, now: now).map { "\n\($0)" } ?? ""
        button.toolTip = "\(headline.service.name) \(headline.row.title): \(Format.percent(headline.row.percent))\(caption)"
    }

    /// Updates the menu's contents in place, rebuilding its item list only if its shape changed.
    private func updateMenu(now: Date) {
        var items: [NSMenuItem] = []
        var used = Set<String>()

        func reused<View: NSView>(_ key: String, _ make: () -> View) -> (NSMenuItem, View) {
            used.insert(key)
            if let item = reusableItems[key], let view = item.view as? View {
                return (item, view)
            }
            let view = make()
            let item = NSMenuItem()
            item.view = view
            reusableItems[key] = item
            return (item, view)
        }
        func separator(_ key: String) -> NSMenuItem {
            used.insert(key)
            if let item = reusableItems[key] {
                return item
            }
            let item = NSMenuItem.separator()
            reusableItems[key] = item
            return item
        }
        func notice(_ key: String, _ text: String, detail: String?, showsIcon: Bool) -> NSMenuItem {
            let (item, view) = reused(key) { NoticeView() }
            view.update(text: text, detail: detail, showsIcon: showsIcon)
            return item
        }

        let services = tracker.signedInServices
        // One notice is enough when every service is offline.
        let allOffline = !services.isEmpty && services.allSatisfy { tracker.state(of: $0)?.problem == .failed(.offline) }
        if allOffline {
            items.append(notice("notice.offline", Format.problem(.failed(.offline), service: .claude), detail: nil, showsIcon: true))
        }
        if services.isEmpty {
            items.append(tracker.isLoading
                ? notice("notice.empty", "Loading…", detail: nil, showsIcon: false)
                : notice("notice.empty", "Sign in to Claude Code or Codex to see your limits.",
                         detail: "Run claude then /login, or codex login.", showsIcon: false))
        }

        for (index, service) in services.enumerated() {
            guard let state = tracker.state(of: service) else { continue }
            if index > 0 || allOffline {
                items.append(separator("separator.\(service.rawValue)"))
            }
            let (header, headerView) = reused("header.\(service.rawValue)") { SectionHeaderView() }
            headerView.update(title: [service.name, state.plan].compactMap { $0 }.joined(separator: " "),
                              logo: ServiceLogo.image(for: service))
            items.append(header)

            // The explanation comes first, above the numbers it qualifies.
            if let problem = state.problem, !allOffline {
                let updated = state.lastUpdated.map { "Updated \(Format.time($0))" }
                let detail = [updated, Format.problemDetail(problem)].compactMap { $0 }.joined(separator: " · ")
                items.append(notice("notice.\(service.rawValue)", Format.problem(problem, service: service),
                                    detail: detail.isEmpty ? nil : detail, showsIcon: true))
            }

            let stale = tracker.isStale(service, at: now)
            let rows = state.usage?.rows(at: now) ?? []
            for row in rows {
                let (item, view) = reused("row.\(service.rawValue).\(row.id)") { LimitRowView() }
                view.update(row: row, stale: stale, now: now)
                items.append(item)
            }
            if rows.isEmpty, state.problem == nil {
                items.append(notice("notice.\(service.rawValue).empty", state.usage == nil ? "Loading…" : "No usage limits reported",
                                    detail: nil, showsIcon: false))
            }
        }

        items.append(separator("separator.actions"))
        let lastUpdated = services.compactMap { tracker.state(of: $0)?.lastUpdated }.max()
        let status = isRefreshing ? "Updating…" : lastUpdated.map { "Updated \(Format.time($0))" }
        if #available(macOS 14.4, *) {
            refreshItem.subtitle = status
        } else if let status {
            used.insert("info.updated")
            let info = reusableItems["info.updated"] ?? NSMenuItem(title: "", action: nil, keyEquivalent: "")
            info.title = status
            reusableItems["info.updated"] = info
            items.append(info)
        }
        items.append(refreshItem)
        if isBundledApp {
            launchAtLoginItem.state = launchesAtLogin ? .on : .off
        } else {
            launchAtLoginItem.action = nil  // only a bundled .app can be a login item
            launchAtLoginItem.toolTip = "Available when running the bundled app"
        }
        items.append(launchAtLoginItem)
        items.append(separator("separator.quit"))
        items.append(quitItem)

        reusableItems = reusableItems.filter { used.contains($0.key) }
        if menu.items.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) {
            menu.items = items
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if isBundledApp {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
        // Countdowns such as "Resets in 3h 5m" move on while the menu is closed.
        updateMenu(now: .now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        if !tracker.isFresh(at: .now) {
            Task { await refresh(force: true) }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        releaseFreedMemory()
    }

    /// Fetching (TLS, JSON) and drawing the menu leave freed but still-dirty heap pages behind.
    /// Once the work has settled, hand them back to the system: about 1 MB measured after a menu
    /// open and close. A few milliseconds, at most once per poll or menu close.
    private func releaseFreedMemory() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !isMenuOpen, !isRefreshing else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        Task { await refresh(force: true) }
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchesAtLogin = service.status == .enabled
        UserDefaults.standard.set(launchesAtLogin || service.status == .requiresApproval, forKey: Self.launchAtLoginKey)
        render()
    }

    /// Each build is ad-hoc signed, so after an update macOS may no longer count the app as
    /// registered. If the person had turned Launch at Login on here, quietly register again;
    /// if they turned it off in System Settings instead (status "requires approval"), leave it.
    private func restoreLaunchAtLogin() {
        guard isBundledApp, UserDefaults.standard.bool(forKey: Self.launchAtLoginKey) else { return }
        let service = SMAppService.mainApp
        if service.status == .notRegistered || service.status == .notFound {
            try? service.register()
        }
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
