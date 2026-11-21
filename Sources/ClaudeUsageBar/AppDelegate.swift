import AppKit
import ServiceManagement
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let client = UsageClient()

    private var usage: UsageResponse?
    private var plan: String?
    private var lastUpdated: Date?
    /// Why the numbers on screen may be out of date, if they are.
    private var problem: String?
    private var nextPoll: Duration = .seconds(120)
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        render()

        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: nextPoll)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: - Fetching

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        apply(await client.fetch())
        render()
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case let .success(usage, plan):
            self.usage = usage
            self.plan = plan
            lastUpdated = .now
            problem = nil
            nextPoll = .seconds(120)
        case let .tokenExpired(plan):
            self.plan = plan
            problem = "Token expired. Use Claude Code to refresh it."
            // Until Claude Code refreshes the token, each poll only re-reads the keychain.
            nextPoll = .seconds(60)
        case .notSignedIn:
            usage = nil
            problem = "Not signed in to Claude Code. Run `claude` and /login."
            nextPoll = .seconds(60)
        case let .rateLimited(retryAfter):
            problem = "Rate limited. Retrying shortly."
            nextPoll = .seconds(max(retryAfter ?? 300, 120))
        case let .failed(message):
            problem = message
            nextPoll = .seconds(120)
        }
    }

    // MARK: - Rendering

    private func render() {
        let rows = usage.map { UsageSummary.rows(from: $0) } ?? []
        let stale = problem != nil
        updateButton(top: UsageSummary.tightest(rows), stale: stale)
        rebuildMenu(rows: rows, stale: stale)
    }

    private func updateButton(top: LimitRow?, stale: Bool) {
        guard let button = statusItem.button else { return }
        let tint = stale ? nil : top?.severity.statusBarColor
        let text = " " + Format.percent(top?.percent)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

        button.image = GaugeIcon.image(fraction: (top?.percent ?? 0) / 100, tint: tint)
        if let tint {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: tint])
        } else {
            // A plain title follows the menu bar's own text colour.
            button.title = text
            button.font = font
        }
        button.appearsDisabled = stale || top == nil
        button.toolTip = top.map { "Claude usage · \($0.title): \(Format.percent($0.percent))" } ?? "Claude usage"
    }

    private func rebuildMenu(rows: [LimitRow], stale: Bool) {
        menu.removeAllItems()

        if rows.isEmpty {
            menu.addItem(infoItem(problem ?? "Loading…"))
        } else {
            for row in rows {
                let view = NSHostingView(rootView: LimitRowView(row: row, dimmed: stale))
                view.frame.size = view.fittingSize
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
            }
            menu.addItem(.separator())
            if let problem {
                menu.addItem(infoItem("⚠︎ " + problem))
            }
            let updated = lastUpdated.map { "Updated \(Format.time($0))" } ?? "Not updated yet"
            menu.addItem(infoItem([plan, updated].compactMap { $0 }.joined(separator: " · ")))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh", #selector(refreshNow), key: "r"))
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        let quit = actionItem("Quit", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        render()  // keeps the "resets in…" countdowns current
    }

    func menuWillOpen(_ menu: NSMenu) {
        if lastUpdated.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await refresh() }
        }
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        Task { await refresh() }
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
