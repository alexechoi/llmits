import AppKit
import SwiftUI
import UsageCore

extension Severity {
    /// Only the menu bar icon is tinted, and only when a limit needs attention, so colour stays
    /// reserved for status as Apple's guidelines ask. `nil` keeps the system's own rendering.
    var statusBarColor: NSColor? {
        switch self {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// The fill colour for a limit's capacity gauge. Normal follows the person's accent colour.
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// The menu bar icon: an SF Symbol whose ring fills with usage (Variable Draw, macOS 26 and later).
enum StatusIcon {
    static func image(fraction: Double, severity: Severity, tint: NSColor?) -> NSImage {
        // A distinct glyph at critical, so the state never depends on colour alone.
        let name = severity == .critical ? "exclamationmark.circle" : "asterisk.circle"
        let value = min(max(fraction, 0), 1)
        let symbol = NSImage(systemSymbolName: name, variableValue: value, accessibilityDescription: "Claude usage")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Claude usage")!

        // Weight-matched to the menu bar's text, at the large scale for emphasis.
        var config = NSImage.SymbolConfiguration(
            pointSize: NSFont.menuBarFont(ofSize: 0).pointSize,
            weight: .regular,
            scale: .large
        )
        if #available(macOS 26, *) {
            config = config.applying(NSImage.SymbolConfiguration(variableValueMode: .draw))
        }
        if let tint {
            // A single palette colour keeps the unfilled part of the ring dimmed; a hierarchical
            // colour would dim the whole ring and hide the fill level.
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        // A template lets the system adapt the icon to the menu bar and its selected state.
        image.isTemplate = tint == nil
        return image
    }
}

/// One limit in the dropdown: name and percentage, a capacity gauge, and when it resets.
struct LimitRowView: View {
    let row: LimitRow
    let dimmed: Bool

    /// Lines the row's text up with the titles of the standard menu items below it.
    static let leadingInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.title)
                Spacer(minLength: 12)
                if row.severity != .normal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(row.severity.color)
                }
                Text(Format.percent(row.percent))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(row.severity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(row.severity.color))
            }
            .font(Font(NSFont.menuFont(ofSize: 0)))

            // A capacity gauge, not a progress bar: Apple keeps progress indicators for
            // transient operations. No gauge when the window isn't open, so nothing implies 0%.
            if let percent = row.percent {
                Gauge(value: min(max(percent, 0), 100), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(row.severity.color)
                .labelsHidden()
            }

            if let caption {
                Text(caption)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.spokenTitle(row))
        .accessibilityValue(Format.spokenValue(row))
    }

    private var caption: String? {
        if let reset = Format.reset(row.resetsAt) {
            return reset
        }
        return row.percent == nil ? "No active session" : nil
    }
}
