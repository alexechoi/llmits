import AppKit
import SwiftUI
import UsageCore

extension Severity {
    /// `nil` for normal, so the menu bar keeps its own colour.
    var statusBarColor: NSColor? {
        switch self {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A ring with a wedge filled clockwise from 12 o'clock.
enum GaugeIcon {
    /// A template image (so it follows the menu bar's colour) unless a tint is given.
    static func image(fraction: Double, tint: NSColor?) -> NSImage {
        let fraction = min(max(fraction, 0), 1)
        let color = tint ?? .black
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let ringRect = rect.insetBy(dx: 1.75, dy: 1.75)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()

            if fraction > 0 {
                let centre = NSPoint(x: rect.midX, y: rect.midY)
                let wedge = NSBezierPath()
                wedge.move(to: centre)
                wedge.appendArc(
                    withCenter: centre,
                    radius: ringRect.width / 2 - 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                wedge.close()
                color.setFill()
                wedge.fill()
            }
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "Claude usage"
        return image
    }
}

/// One limit in the dropdown: name and percentage, a bar, and when it resets.
struct LimitRowView: View {
    let row: LimitRow
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                Spacer(minLength: 12)
                Text(Format.percent(row.percent))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(row.severity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(row.severity.color))
            }
            UsageBar(fraction: (row.percent ?? 0) / 100, color: row.severity.color)
            if let reset = Format.reset(row.resetsAt) {
                caption(reset)
            } else if row.percent == nil {
                caption("No active session")
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: 270, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}
