import AppKit
import ServiceManagement
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// What the app knows about one service.
    private struct ServiceState {
        var signedIn = false
        var usage: ServiceUsage?
        var plan: String?
        var lastUpdated: Date?
        /// Why the numbers may be out of date, if they are.
        var problem: Problem?
        var nextFetch = Date.distantPast
        /// Set after rate limiting; not even a manual refresh fetches before then.
        var backoffUntil: Date?
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sources: [any UsageSource] = [ClaudeSource(), ChatGPTSource()]
    private var states: [Service: ServiceState] = [:]
    private var isRefreshing = false

    private var isMenuOpen = false
    /// The menu is only rebuilt when it's about to be seen; while closed, changes just mark it.
    private var menuIsDirty = true
    /// Row views are kept and updated in place, so an open menu never rebuilds under the pointer.
    private var rowItems: [String: NSMenuItem] = [:]
    private var headerItems: [Service: NSMenuItem] = [:]
    private var lastButton: ButtonContent?
    /// Asking ServiceManagement is a cross-process call, so it's checked once per menu opening.
    private var launchesAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remember the item's position, and let people ⌘-drag it out of the menu bar to remove
        // it (which quits the app): it's their choice whether it lives there, not the app's.
        statusItem.autosaveName = "ClaudeUsageBar"
        statusItem.behavior = .terminationOnRemoval
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        render()

        Task {
            while !Task.isCancelled {
                await refresh(force: false)
                let next = states.values.map(\.nextFetch).min() ?? .now.addingTimeInterval(120)
                // The tolerance lets macOS batch this wake-up with others to save energy.
                try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 5)), tolerance: .seconds(10))
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
        let due = sources.filter { source in
            let state = states[source.service] ?? ServiceState()
            if let until = state.backoffUntil, until > now { return false }
            return force || state.nextFetch <= now
        }
        guard !due.isEmpty else { return }

        isRefreshing = true
        render()  // shows "Updating…"
        let outcomes = await withTaskGroup(of: (Service, FetchOutcome).self) { group in
            for source in due {
                group.addTask { (source.service, await source.fetch(now: now)) }
            }
            var outcomes: [(Service, FetchOutcome)] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
        for (service, outcome) in outcomes {
            apply(outcome, to: service)
        }
        isRefreshing = false
        render()
        releaseFreedMemory()
    }

    private func apply(_ outcome: FetchOutcome, to service: Service) {
        var state = states[service] ?? ServiceState()
        let now = Date.now
        state.backoffUntil = nil

        switch outcome {
        case let .success(usage):
            state.signedIn = true
            state.usage = usage
            state.plan = usage.plan
            state.lastUpdated = now
            state.problem = nil
            state.nextFetch = now.addingTimeInterval(120)
        case let .tokenExpired(plan):
            state.signedIn = true
            state.plan = plan ?? state.plan
            state.problem = .tokenExpired
            // Until the tool renews the token, each check only re-reads the stored login.
            state.nextFetch = now.addingTimeInterval(60)
        case .notSignedIn:
            state = ServiceState()
            // Check now and then in case someone signs in.
            state.nextFetch = now.addingTimeInterval(300)
        case let .rateLimited(retryAfter):
            let until = now.addingTimeInterval(max(retryAfter ?? 300, 120))
            state.problem = .rateLimited(until: until)
            state.backoffUntil = until
            state.nextFetch = until
        case let .failed(failure):
            state.problem = .failed(failure)
            state.nextFetch = now.addingTimeInterval(failure == .offline ? 60 : 120)
        }
        states[service] = state
    }

    // MARK: - Rendering

    private var signedInServices: [(service: Service, state: ServiceState)] {
        Service.allCases.compactMap { service in
            guard let state = states[service], state.signedIn else { return nil }
            return (service, state)
        }
    }

    private func render() {
        let now = Date.now
        let visible = signedInServices

        // Fresh numbers win: a service that's out of date must never hide a live warning.
        var stale = false
        var top = UsageSummary.tightest(in: visible.filter { $0.state.problem == nil }.compactMap(\.state.usage), now: now)
        if top == nil {
            top = UsageSummary.tightest(in: visible.compactMap(\.state.usage), now: now)
            stale = true
        }
        updateButton(top: top, stale: stale, now: now)

        menuIsDirty = true
        if isMenuOpen {
            updateMenu(visible, now: now)
        }
    }

    private struct ButtonContent: Equatable {
        var symbolFraction: Double
        var severity: Severity
        var tinted: Bool
        var title: String
    }

    private func updateButton(top: (service: Service, row: LimitRow)?, stale: Bool, now: Date) {
        guard let button = statusItem.button else { return }
        let severity = top?.row.severity ?? .normal
        // Colour goes on the icon only, never the text, so the percentage keeps the menu bar's
        // own contrast on any wallpaper. Stale data drops the colour altogether.
        let tint = stale ? nil : severity.statusBarColor
        let content = ButtonContent(
            // Variable Draw shows coarse steps anyway, so whole percents are plenty.
            symbolFraction: ((top?.row.percent ?? 0).rounded(.down)) / 100,
            severity: severity,
            tinted: tint != nil,
            title: Format.percent(top?.row.percent)
        )
        if content != lastButton {
            button.image = StatusIcon.image(fraction: content.symbolFraction, severity: severity, tint: tint)
            button.title = content.title
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            lastButton = content
        }
        button.appearsDisabled = top == nil || stale

        button.setAccessibilityLabel("Usage limits")
        guard let top else {
            button.setAccessibilityValue("No data")
            button.toolTip = "Usage limits"
            return
        }
        button.setAccessibilityValue("\(top.service.name), \(Format.spokenTitle(top.row)): \(Format.spokenValue(top.row, stale: stale, now: now))")
        let caption = Format.caption(top.row, now: now).map { "\n\($0)" } ?? ""
        button.toolTip = "\(top.service.name) \(top.row.title): \(Format.percent(top.row.percent))\(caption)"
    }

    /// Updates the menu's contents, reusing every row view it can.
    private func updateMenu(_ visible: [(service: Service, state: ServiceState)], now: Date) {
        menuIsDirty = false
        var items: [NSMenuItem] = []
        var usedRowKeys = Set<String>()

        // One notice is enough when every service is offline.
        let allOffline = !visible.isEmpty && visible.allSatisfy { $0.state.problem == .failed(.offline) }
        if allOffline {
            items.append(noticeItem(Format.problem(.failed(.offline), service: .claude), detail: nil, showsIcon: true))
        }

        if visible.isEmpty {
            let nothingYet = Service.allCases.contains { states[$0] == nil }
            items.append(noticeItem(
                nothingYet ? "Loading…" : "Sign in to Claude Code or Codex to see your limits.",
                detail: nothingYet ? nil : "Run claude then /login, or codex login.",
                showsIcon: false
            ))
        }

        for (index, (service, state)) in visible.enumerated() {
            if index > 0 || allOffline {
                items.append(.separator())
            }
            items.append(headerItem(for: service, plan: state.plan))

            // The explanation comes first, above the numbers it qualifies.
            if let problem = state.problem, !allOffline {
                let updated = state.lastUpdated.map { "Updated \(Format.time($0))" }
                let detail = [updated, Format.problemDetail(problem)].compactMap { $0 }.joined(separator: " · ")
                items.append(noticeItem(Format.problem(problem, service: service), detail: detail.isEmpty ? nil : detail, showsIcon: true))
            }

            let rows = state.usage?.rows(at: now) ?? []
            for row in rows {
                let key = "\(service.rawValue).\(row.id)"
                usedRowKeys.insert(key)
                let item = rowItems[key] ?? {
                    let item = NSMenuItem()
                    item.view = LimitRowView()
                    rowItems[key] = item
                    return item
                }()
                (item.view as? LimitRowView)?.update(row: row, stale: state.problem != nil, now: now)
                items.append(item)
            }
            if rows.isEmpty, state.problem == nil {
                items.append(noticeItem(state.usage == nil ? "Loading…" : "No usage limits reported", detail: nil, showsIcon: false))
            }
        }
        rowItems = rowItems.filter { usedRowKeys.contains($0.key) }

        items.append(.separator())
        let refresh = actionItem("Refresh", #selector(refreshNow), key: "r")
        let updated = visible.compactMap(\.state.lastUpdated).max().map { "Updated \(Format.time($0))" }
        if let status = isRefreshing ? "Updating…" : updated {
            if #available(macOS 14.4, *) {
                refresh.subtitle = status
            } else {
                items.append(infoItem(status))
            }
        }
        items.append(refresh)
        items.append(launchAtLoginItem())
        items.append(.separator())
        let quit = actionItem("Quit Claude Usage Bar", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        items.append(quit)

        // Swapping the whole item list in one go keeps an open menu steady.
        menu.items = items
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if isBundledApp {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
        // Countdowns such as "Resets in 3h 5m" move on while the menu is closed.
        updateMenu(signedInServices, now: .now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        let oldest = states.values.filter(\.signedIn).compactMap(\.lastUpdated).min()
        if oldest.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
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

    private func launchAtLoginItem() -> NSMenuItem {
        let item = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
        if isBundledApp {
            item.state = launchesAtLogin ? .on : .off
        } else {
            item.action = nil  // only a bundled .app can be a login item
            item.toolTip = "Available when running the bundled app"
        }
        return item
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
        render()
    }

    // MARK: - Helpers

    /// A service's heading, with its logo. Reused, like the rows.
    private func headerItem(for service: Service, plan: String?) -> NSMenuItem {
        let item = headerItems[service] ?? {
            let item = NSMenuItem()
            item.view = SectionHeaderView()
            headerItems[service] = item
            return item
        }()
        let title = [service.name, plan].compactMap { $0 }.joined(separator: " ")
        (item.view as? SectionHeaderView)?.update(title: title, logo: ServiceLogo.image(for: service))
        return item
    }

    /// A notice that wraps and reads at full contrast, unlike a disabled menu item.
    private func noticeItem(_ text: String, detail: String?, showsIcon: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = NoticeView(text: text, detail: detail, showsIcon: showsIcon)
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
