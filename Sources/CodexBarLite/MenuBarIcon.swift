import AppKit

/// Draws the menu-bar glyph: N concentric rings (Apple Fitness style), one per
/// provider. Sized to the current menu-bar thickness so it fills any bar
/// (including the taller notched-Mac bar), and drawn through a handler that
/// re-runs per display, so it stays crisp on Retina and non-Retina screens.
/// Non-template so colours are always visible.
enum MenuBarIcon {
    /// Build the icon from the current states dictionary, sized to the menu bar.
    static func image(states: [ProviderID: ProviderState]) -> NSImage {
        let side = NSStatusBar.system.thickness
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(states: states, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Render the rings into `rect` (the destination the drawing handler hands us,
    /// so all geometry scales to whatever size the system asks to draw).
    private static func draw(states: [ProviderID: ProviderState], in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let lineWidth = max(1.5, side * 0.11)
        let margin = side * 0.03
        let providers = Array(ProviderID.allCases.prefix(3))
        let radii = self.radii(count: providers.count, side: side,
                               lineWidth: lineWidth, margin: margin)
        let trackColor = NSColor(white: 0.5, alpha: 1)

        for (i, id) in providers.enumerated() {
            let r = radii[i]
            drawTrack(center: center, radius: r, lineWidth: lineWidth, color: trackColor)

            let fraction: Double?
            if case let .success(usage) = states[id],
               let pct = usage.fiveHour?.remainingPercent {
                fraction = pct / 100.0
            } else {
                fraction = nil
            }
            drawRing(center: center, radius: r, lineWidth: lineWidth,
                     fraction: fraction, color: color(for: id))
        }
    }

    /// Radii for 1…N concentric rings, scaled to `side`. The outer ring sits one
    /// half-stroke + margin inside the canvas; each inner ring steps in by a
    /// stroke-width plus a small gap so the rings stay visibly separated. At an
    /// 18 pt bar this yields ~[7.5, 5]; it scales proportionally for taller bars.
    private static func radii(count: Int, side: CGFloat,
                              lineWidth: CGFloat, margin: CGFloat) -> [CGFloat] {
        let outer = side / 2 - lineWidth / 2 - margin
        let step = lineWidth + max(0.5, margin)
        return (0..<count).map { outer - CGFloat($0) * step }
    }

    /// Per-provider colours (Apple Fitness palette).
    private static func color(for provider: ProviderID) -> NSColor {
        switch provider {
        case .codex:  NSColor(red: 1, green: 0.18, blue: 0.33, alpha: 1)
        case .claude: NSColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
        }
    }

    /// Full background ring (track) so the outline is visible even at 0 %.
    private static func drawTrack(center: NSPoint, radius: CGFloat, lineWidth: CGFloat,
                                  color: NSColor)
    {
        color.setStroke()
        let rect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// Draw one incomplete ring (arc with rounded caps) from 12 o'clock clockwise.
    /// Full coverage is drawn as a complete oval to avoid a visible seam at the caps.
    ///
    /// Round caps extend `lineWidth/2` past each geometric endpoint along the arc,
    /// which would otherwise make the *visible* arc longer than `fraction`. We trim
    /// the drawn arc by that half-cap angle on both ends so the rendered arc (caps
    /// included) spans exactly `fraction` of the circle.
    private static func drawRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat,
                                  fraction: Double?, color: NSColor)
    {
        guard let fraction, fraction > 0.001 else { return }

        if fraction >= 0.999 {
            color.setStroke()
            let rect = NSRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            path.stroke()
            return
        }

        let arcDeg = 360 * CGFloat(fraction)
        let capDeg = (lineWidth / 2) / radius * (180 / .pi)   // angular half-cap

        // Too short to trim — the two caps would meet/overlap. Draw a single dot
        // at 12 o'clock so a near-empty ring still reads as "a sliver left".
        guard arcDeg > 2 * capDeg else {
            color.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - lineWidth / 2,
                                                  y: center.y + radius - lineWidth / 2,
                                                  width: lineWidth, height: lineWidth))
            dot.fill()
            return
        }

        color.setStroke()
        let path = NSBezierPath()
        path.appendArc(withCenter: center,
                       radius: radius,
                       startAngle: 90 - capDeg,
                       endAngle: 90 - arcDeg + capDeg,
                       clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()
    }
}
