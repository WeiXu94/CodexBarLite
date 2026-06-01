import AppKit

/// Draws the menu-bar glyph: a ring whose filled wedge represents the most
/// constrained remaining capacity across both subs. Rendered as a template image
/// so it adapts to light/dark menu bars automatically.
enum MenuBarIcon {
    static func image(remaining: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset: CGFloat = 2
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        NSColor.black.set()

        // Track: thin outline circle.
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 1.5
        track.stroke()

        // Filled wedge for remaining capacity (clockwise from 12 o'clock).
        if let remaining {
            let fraction = max(0, min(1, remaining))
            if fraction > 0 {
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(
                    withCenter: center,
                    radius: radius - 0.75,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true)
                wedge.close()
                wedge.fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
