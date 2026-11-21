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

/// The menu bar icon: a ring that fills clockwise with usage around a diamond, echoing the usage
/// icon in the ChatGPT app, with "!" in place of the diamond at critical so the state never
/// depends on colour alone.
///
/// It's drawn by hand as a true template image (shapes and opacity only) so macOS can recolour it
/// for light, dark and wallpaper-tinted menu bars, the highlighted state and Increase Contrast.
/// SF Symbols' Variable Draw looked similar but always draws black, so it vanished on dark bars.
enum StatusIcon {
    static let size = NSSize(width: 16, height: 16)

    static func image(fraction: Double, severity: Severity, tint: NSColor?) -> NSImage {
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let image = NSImage(size: size, flipped: false) { rect in
            // Black in a template becomes the menu bar's own colour; a tint is drawn as-is.
            let colour = tint ?? .black
            let lineWidth: CGFloat = 1.6
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - lineWidth / 2 - 0.4

            // The unused part of the ring, faint enough that the used part reads at a glance.
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            colour.withAlphaComponent(0.32).setStroke()
            track.stroke()

            if fraction > 0 {
                // Clockwise from 12 o'clock. Any usage at all shows at least a short arc.
                let sweep = 360 * max(fraction, 0.03)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                colour.setStroke()
                arc.stroke()
            }

            colour.setFill()
            if severity == .critical {
                let bar = NSRect(x: centre.x - 0.85, y: centre.y - 0.6, width: 1.7, height: 4.2)
                NSBezierPath(roundedRect: bar, xRadius: 0.85, yRadius: 0.85).fill()
                NSBezierPath(ovalIn: NSRect(x: centre.x - 1, y: centre.y - 3.6, width: 2, height: 2)).fill()
            } else {
                let half: CGFloat = 3.1
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: centre.x, y: centre.y + half))
                diamond.line(to: NSPoint(x: centre.x + half, y: centre.y))
                diamond.line(to: NSPoint(x: centre.x, y: centre.y - half))
                diamond.line(to: NSPoint(x: centre.x - half, y: centre.y))
                diamond.close()
                diamond.lineJoinStyle = .round
                diamond.lineWidth = 0.8  // softens the corners, like SF Symbols' diamonds
                diamond.fill()
                colour.setStroke()
                diamond.stroke()
            }
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "Usage limits"
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

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 24))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        textLabel.font = MenuMetrics.font
        detailLabel.font = MenuMetrics.smallFont
        detailLabel.textColor = .secondaryLabelColor
        for view in [icon, textLabel, detailLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    func update(text: String, detail: String?, showsIcon: Bool) {
        icon.isHidden = !showsIcon
        textLabel.stringValue = text
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
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

/// Each service's own mark, beside its section header. Single-colour and otherwise unaltered,
/// drawn in the header's colour so it reads as a label rather than a badge.
@MainActor
enum ServiceLogo {
    private static var cache: [Service: NSImage] = [:]

    static func image(for service: Service) -> NSImage? {
        if let image = cache[service] {
            return image
        }
        let name = switch service {
        case .claude: "claude-spark"
        case .chatGPT: "openai-blossom"
        }
        // Bundled by scripts/build-app.sh; absent under `swift run`, where headers show text only.
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: SectionHeaderView.logoSize, height: SectionHeaderView.logoSize)
        image.accessibilityDescription = service.name
        cache[service] = image
        return image
    }
}

/// A service's section heading: its logo and plan, e.g. "Claude Max 20x".
final class SectionHeaderView: NSView {
    static let logoSize: CGFloat = 12

    private let logo = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 24))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        for view in [logo, titleLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(title: String, logo image: NSImage?) {
        titleLabel.stringValue = title
        logo.image = image
        logo.isHidden = image == nil
        setAccessibilityLabel(title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x = MenuMetrics.leading
        if !logo.isHidden {
            let side = Self.logoSize
            logo.frame = NSRect(x: x, y: (height - side) / 2, width: side, height: side)
            x += side + 6
        }
        let textHeight = titleLabel.fittingSize.height
        titleLabel.frame = NSRect(
            x: x - MenuMetrics.textPadding,
            y: (height - textHeight) / 2,
            width: MenuMetrics.width - x - MenuMetrics.trailing,
            height: textHeight
        )
    }
}
