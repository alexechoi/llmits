import AppKit
import UsageCore

// The menu's custom rows are plain AppKit views with manual layout. SwiftUI rows looked the same
// but cost 7–8 MB once drawn, over a quarter of the app's memory.

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

    /// A bar's fill: neutral while all's well, so colour only ever means trouble (an accent
    /// colour could be red or orange and read as a warning).
    var barColor: NSColor {
        switch self {
        case .normal: .secondaryLabelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// A glyph beside the percentage, so warning and critical differ in shape, not just colour.
    var symbolName: String? {
        switch self {
        case .normal: nil
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.circle.fill"
        }
    }
}

/// Measurements shared by the custom menu views, matched to macOS 27's standard menu items.
enum MenuMetrics {
    static let width: CGFloat = 280
    /// Lines text up with the titles of standard items, and trailing content with their shortcuts.
    static let leading: CGFloat = 16
    static let trailing: CGFloat = 18
    /// NSTextField draws its text this far inside its frame, so label frames sit this much
    /// further out for the text itself to line up with bars and standard items.
    static let textPadding: CGFloat = 2
    static var font: NSFont { .menuFont(ofSize: 0) }
    static var smallFont: NSFont { .menuFont(ofSize: NSFont.smallSystemFontSize) }
}

/// The menu bar icon: a ring that fills with usage (SF Symbols Variable Draw, macOS 26 and
/// later) around a diamond, echoing the usage icon in the ChatGPT app.
enum StatusIcon {
    static func image(fraction: Double, severity: Severity, tint: NSColor?) -> NSImage {
        // A distinct glyph at critical, so the state never depends on colour alone.
        let name = severity == .critical ? "exclamationmark.circle" : "diamond.circle"
        let value = min(max(fraction, 0), 1)
        let symbol = NSImage(systemSymbolName: name, variableValue: value, accessibilityDescription: "Usage limits")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Usage limits")!

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

/// One limit in the menu: its name and percentage, a bar, and when it resets.
final class LimitRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let severityIcon = NSImageView()
    private let bar = CapacityBarView()
    private let captionLabel = NSTextField(labelWithString: "")

    private static let padding: CGFloat = 4
    private static let spacing: CGFloat = 3

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 40))
        titleLabel.font = MenuMetrics.font
        titleLabel.lineBreakMode = .byTruncatingTail
        percentLabel.font = .monospacedDigitSystemFont(ofSize: MenuMetrics.font.pointSize, weight: .medium)
        captionLabel.font = MenuMetrics.smallFont
        captionLabel.textColor = .secondaryLabelColor
        for view in [titleLabel, percentLabel, severityIcon, bar, captionLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        // VoiceOver reads the row as one element: its title, then the spoken value.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(row: LimitRow, stale: Bool, now: Date) {
        titleLabel.stringValue = row.title
        // Full-contrast text: the colour lives in the bar and the glyph, never in the digits.
        percentLabel.stringValue = Format.percent(row.percent)

        if let name = row.severity.symbolName {
            severityIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .semibold))
            severityIcon.contentTintColor = row.severity.barColor
            severityIcon.isHidden = false
        } else {
            severityIcon.isHidden = true
        }

        // No bar when the window isn't open, so nothing implies 0%.
        bar.isHidden = row.percent == nil
        // Out-of-date numbers keep readable text; only the bar fades.
        bar.configure(
            fraction: (row.percent ?? 0) / 100,
            elapsed: row.elapsedFraction(at: now),
            color: stale ? .tertiaryLabelColor : row.severity.barColor
        )
        bar.toolTip = row.windowLength.map { _ in "The mark shows an even pace: how much of this window has passed." }

        let caption = Format.caption(row, now: now)
        captionLabel.stringValue = caption ?? ""
        captionLabel.isHidden = caption == nil

        setAccessibilityLabel(Format.spokenTitle(row))
        setAccessibilityValue(Format.spokenValue(row, stale: stale, now: now))
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let width = MenuMetrics.width
        var y = Self.padding

        let percentSize = percentLabel.fittingSize
        let titleHeight = max(titleLabel.fittingSize.height, percentSize.height)
        let percentX = width - MenuMetrics.trailing + MenuMetrics.textPadding - percentSize.width
        percentLabel.frame = NSRect(x: percentX, y: y, width: percentSize.width, height: titleHeight)

        var titleRight = percentX - 8
        if !severityIcon.isHidden {
            let side: CGFloat = 13
            severityIcon.frame = NSRect(x: percentX - 4 - side, y: y + (titleHeight - side) / 2, width: side, height: side)
            titleRight = severityIcon.frame.minX - 6
        }
        let textX = MenuMetrics.leading - MenuMetrics.textPadding
        titleLabel.frame = NSRect(x: textX, y: y, width: max(titleRight - textX, 0), height: titleHeight)
        y += titleHeight + Self.spacing

        if !bar.isHidden {
            bar.frame = NSRect(x: MenuMetrics.leading, y: y, width: width - MenuMetrics.leading - MenuMetrics.trailing, height: CapacityBarView.height)
            y += CapacityBarView.height + Self.spacing
        }
        if !captionLabel.isHidden {
            let captionHeight = captionLabel.fittingSize.height
            captionLabel.frame = NSRect(x: textX, y: y, width: width - textX - MenuMetrics.trailing, height: captionHeight)
            y += captionHeight
        }
        let height = ceil(y + Self.padding)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }
}

/// How much of a limit is used: a slim capacity bar, plus a mark for how much of the window has
/// passed. It's a level, not a progress indicator (Apple keeps those for transient work), and
/// the system's capacity gauge draws about 16pt tall in a menu, too heavy for a glanceable list.
final class CapacityBarView: NSView {
    /// The view's height: a 6pt bar, with room for the pace mark to stand proud of it.
    static let height: CGFloat = 10
    private static let barHeight: CGFloat = 6

    private var fraction: Double = 0
    private var elapsed: Double?
    private var color: NSColor = .secondaryLabelColor

    override var isFlipped: Bool { true }

    func configure(fraction: Double, elapsed: Double?, color: NSColor) {
        let fraction = min(max(fraction, 0), 1)
        guard fraction != self.fraction || elapsed != self.elapsed || color != self.color else { return }
        self.fraction = fraction
        self.elapsed = elapsed
        self.color = color
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true  // the semantic colours resolve differently in light and dark
    }

    override func draw(_ dirtyRect: NSRect) {
        let barHeight = Self.barHeight
        let track = NSRect(x: 0, y: (bounds.height - barHeight) / 2, width: bounds.width, height: barHeight)
        let radius = barHeight / 2

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        if fraction > 0 {
            // Any usage at all shows as at least a dot, so 1% doesn't read as empty.
            var fill = track
            fill.size.width = max(track.width * fraction, barHeight)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }

        if let elapsed {
            // Standing a little proud of the bar keeps the mark visible over any fill colour.
            let x = (track.width - 1.5) * elapsed
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: 1.5, height: bounds.height), xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}

/// A short message in the menu, such as why numbers are out of date. Unlike a disabled menu
/// item it reads at full contrast, wraps instead of widening the menu, and isn't "dimmed" to
/// VoiceOver.
final class NoticeView: NSView {
    private let icon = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(text: String, detail: String?, showsIcon: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 24))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.isHidden = !showsIcon
        textLabel.font = MenuMetrics.font
        textLabel.stringValue = text
        detailLabel.font = MenuMetrics.smallFont
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        for view in [icon, textLabel, detailLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([text, detail].compactMap { $0 }.joined(separator: ", "))
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let width = MenuMetrics.width
        var x = MenuMetrics.leading
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: 5, width: 14, height: 14)
            x += 20
        }
        x -= MenuMetrics.textPadding
        let textWidth = width - x - MenuMetrics.trailing + MenuMetrics.textPadding
        textLabel.preferredMaxLayoutWidth = textWidth
        // The cell's own measurement for this width, so long messages wrap rather than clip.
        let bounds = NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
        let textHeight = ceil(textLabel.cell?.cellSize(forBounds: bounds).height ?? textLabel.fittingSize.height)
        textLabel.frame = NSRect(x: x, y: 4, width: textWidth, height: textHeight)
        var y = 4 + textHeight
        if !detailLabel.isHidden {
            let detailHeight = detailLabel.fittingSize.height
            detailLabel.frame = NSRect(x: x, y: y + 1, width: textWidth, height: detailHeight)
            y += detailHeight + 1
        }
        let height = ceil(y + 4)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }
}
