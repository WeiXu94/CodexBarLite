import AppKit

/// Draws the menu-bar glyph: N concentric rings (Apple Fitness style), one per
/// provider. Radii are computed dynamically so 1, 2, or 3 providers all look
/// balanced. Non-template so colours are always visible.
enum MenuBarIcon {
    /// Build the icon from the current states dictionary.
    static func image(states: [ProviderID: ProviderState]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: 9, y: 9)
        let providers = Array(ProviderID.allCases.prefix(3))
        let radii = self.radii(for: providers.count)
        let lineWidth: CGFloat = 2
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

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Radii for 1…3 providers. Outer ring is ~6.5, subsequent rings step inward
    /// by ~2 pt to keep visible separation at 18×18.
    private static func radii(for count: Int) -> [CGFloat] {
        switch count {
        case 1:  [5.5]
        case 2:  [6.5, 4]
        case 3:  [6.5, 4.5, 2.5]
        default: []
        }
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
