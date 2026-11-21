import AppKit
import ServiceManagement
import SwiftUI
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
        var problem: String?
        var nextFetch = Date.distantPast
        /// Set after rate limiting; not even a manual refresh fetches before then.
        var backoffUntil: Date?
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sources: [any UsageSource] = [ClaudeSource(), ChatGPTSource()]
    private var states: [Service: ServiceState] = [:]
    private var isRefreshing = false

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

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
    }

    // MARK: - Fetching

    /// Fetches every service that's due, or all of them when `force` is set (except any that
    /// asked to be left alone after rate limiting), concurrently.
    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date.now
        let due = sources.filter { source in
            let state = states[source.service] ?? ServiceState()
            if let until = state.backoffUntil, until > now { return false }
            return force || state.nextFetch <= now
        }
        guard !due.isEmpty else { return }

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
        render()
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
            state.problem = "Token expired. Use \(service.loginTool) to refresh it."
            // Until the tool renews the token, each check only re-reads the stored login.
            state.nextFetch = now.addingTimeInterval(60)
        case .notSignedIn:
            state = ServiceState()
            // Check now and then in case someone signs in.
            state.nextFetch = now.addingTimeInterval(300)
        case let .rateLimited(retryAfter):
            let wait = max(retryAfter ?? 300, 120)
            state.problem = "Rate limited. Retrying shortly."
            state.backoffUntil = now.addingTimeInterval(wait)
            state.nextFetch = now.addingTimeInterval(wait)
        case let .failed(message):
            state.problem = message
            state.nextFetch = now.addingTimeInterval(120)
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
        let top = UsageSummary.tightest(in: visible.compactMap(\.state.usage), now: now)
        let stale = top.map { states[$0.service]?.problem != nil } ?? true
        updateButton(top: top, stale: stale)
        rebuildMenu(visible, now: now)
    }

    private func updateButton(top: (service: Service, row: LimitRow)?, stale: Bool) {
        guard let button = statusItem.button else { return }
        let severity = top?.row.severity ?? .normal
        // Colour goes on the icon only, never the text, so the percentage keeps the menu bar's
        // own contrast on any wallpaper. Stale data drops the colour altogether.
        let tint = stale ? nil : severity.statusBarColor

        button.image = StatusIcon.image(fraction: (top?.row.percent ?? 0) / 100, severity: severity, tint: tint)
        button.title = Format.percent(top?.row.percent)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.appearsDisabled = stale

        guard let top else {
            button.setAccessibilityLabel("Usage limits")
            button.setAccessibilityValue("No data")
            button.toolTip = "Usage limits"
            return
        }
        button.setAccessibilityLabel("Usage limits")
        button.setAccessibilityValue("\(top.service.name), \(Format.spokenTitle(top.row)): \(Format.spokenValue(top.row))")
        button.toolTip = "\(top.service.name) · \(top.row.title): \(Format.percent(top.row.percent))"
    }

    private func rebuildMenu(_ visible: [(service: Service, state: ServiceState)], now: Date) {
        menu.removeAllItems()

        if visible.isEmpty {
            let nothingYet = Service.allCases.contains { states[$0] == nil }
            menu.addItem(infoItem(nothingYet ? "Loading…" : "Sign in to Claude Code or Codex to see your limits."))
        }

        for (index, (service, state)) in visible.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(.sectionHeader(title: [service.name, state.plan].compactMap { $0 }.joined(separator: " ")))

            let rows = state.usage?.rows(at: now) ?? []
            for row in rows {
                let view = NSHostingView(rootView: LimitRowView(row: row, dimmed: state.problem != nil))
                view.frame.size = view.fittingSize
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
            }
            if let problem = state.problem {
                let item = infoItem(problem)
                if let lastUpdated = state.lastUpdated {
                    let note = "Last updated \(Format.time(lastUpdated))"
                    if #available(macOS 14.4, *) {
                        item.subtitle = note
                    } else {
                        item.title += " \(note)."
                    }
                }
                menu.addItem(item)
            } else if rows.isEmpty {
                menu.addItem(infoItem(state.usage == nil ? "Loading…" : "No usage limits reported"))
            }
        }

        if let updated = visible.compactMap(\.state.lastUpdated).max() {
            menu.addItem(.separator())
            menu.addItem(infoItem("Updated \(Format.time(updated))"))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh", #selector(refreshNow), key: "r"))
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        let quit = actionItem("Quit Claude Usage Bar", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        render()  // keeps the "resets in…" countdowns current
    }

    func menuWillOpen(_ menu: NSMenu) {
        let newest = states.values.compactMap(\.lastUpdated).min()
        if newest.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await refresh(force: true) }
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
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        render()
    }

    // MARK: - Helpers

    private func infoItem(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
