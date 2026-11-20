import Cocoa
// Morphit icon, in the style of the suite (same squircle, materials, shadows and grain as Grabit's):
// a violet squircle, lavender at the top and plum at the bottom. The motif is two curved arrows
// turning around a square that becomes a circle, drawn by hand.
// Usage: swift scripts/make-icon.swift <folder>  →  <folder>/AppIcon.iconset (+ icon-preview.png)
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// macOS icon shape: rectangle with continuous corners, 824×824 on 1024 with radius ≈ 22.5%.
func squirclePath(_ r: CGRect) -> CGPath {
    let R = min(r.width, r.height) * 0.225
    let p = CGMutablePath()
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (i, (c, d1, d2)) in corners.enumerated() {
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x - d1.dx * u * R + d2.dx * v * R, y: c.y - d1.dy * u * R + d2.dy * v * R)
        }
        if i == 0 { p.move(to: pt(1.52866483, 0)) } else { p.addLine(to: pt(1.52866483, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0.02065399))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905607), control2: pt(0.16905607, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0.02065399, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
    }

    let m = s * 100 / 1024, side = s * 824 / 1024
    let rect = CGRect(x: m, y: m, width: side, height: side)
    let squircle = squirclePath(rect)

    // Outer shadow: wide and faint + tight contact shadow.
    for (off, blur, a) in [(0.014, 0.04, 0.28), (0.003, 0.006, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * off), blur: s * blur, color: c(0, 0, 0, a))
        ctx.addPath(squircle); ctx.setFillColor(c(90, 92, 98)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Base: the app colour, lavender at the top, plum at the bottom.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad([c(170, 150, 228), c(146, 116, 204), c(112, 66, 142)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // 16×16 grid inside the squircle (y up).
    let u = side / 16
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: m + x * u, y: m + y * u) }

    /// Fills `path` with an opaque material: drop shadow, vertical gradient, bright top edge and darker bottom edge.
    func material(_ path: CGPath, top: CGColor, bottom: CGColor, shadowAlpha: CGFloat) {
        let box = path.boundingBoxOfPath
        for (off, blur, a) in [(0.16, 0.22, shadowAlpha), (0.5, 1.0, shadowAlpha * 0.65)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -u * off), blur: u * blur, color: c(20, 20, 26, a * 0.55))
            ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // Body: lighter at the top of each object, darker at its bottom (light from above).
        ctx.drawLinearGradient(grad([top, bottom], [0, 1]),
                               start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        // Rim: a band of constant width along the inside of the outline. Its colour depends on which way
        // the edge faces: lit where it faces up, in shade where it faces down, fading smoothly on the sides.
        // Each layer paints the part of the band that leaves the shape when moved up (or down) by an
        // increasing distance; flat top edges collect every layer, slanted edges fewer, vertical sides none.
        let lw = max(1, u * 0.085)
        ctx.addPath(path); ctx.setLineWidth(lw * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
        func rim(up: Bool, alpha: CGFloat, _ color: (CGFloat) -> CGColor) {
            let steps = 10
            let a = 1 - pow(1 - alpha, 1 / CGFloat(steps))
            for k in 1...steps {
                let shift = lw * 0.45 * CGFloat(k) * (up ? -1 : 1)
                let band = CGMutablePath()
                band.addRect(box.insetBy(dx: -u * 2, dy: -u * 2))
                band.addPath(path, transform: CGAffineTransform(translationX: 0, y: shift))
                ctx.addPath(band); ctx.setFillColor(color(a)); ctx.fillPath(using: .evenOdd)
            }
        }
        // A faint light line all around, as on Scene's windows, so the rim reads as one continuous edge.
        ctx.setFillColor(c(255, 255, 255, 0.3)); ctx.fill(box.insetBy(dx: -u, dy: -u))
        rim(up: true, alpha: 0.8) { c(255, 255, 255, $0) }
        rim(up: false, alpha: 0.2) { c(0, 0, 0, $0) }
        ctx.restoreGState()
    }

    // Two arcs turning clockwise around the centre, each ending in an arrowhead.
    let centre = P(8, 8)
    let radius = 5.0 * u, stroke = 0.95 * u
    func arcArrow(from a0: CGFloat, to a1: CGFloat) -> CGPath {
        // Angles in degrees, y up; clockwise from a0 to a1.
        let r0 = a0 * .pi / 180, r1 = a1 * .pi / 180
        let arc = CGMutablePath()
        arc.addArc(center: centre, radius: radius, startAngle: r0, endAngle: r1, clockwise: true)
        let tip = CGPoint(x: centre.x + radius * cos(r1), y: centre.y + radius * sin(r1))
        // Direction of travel at the end (clockwise tangent) and the arrowhead's two wings.
        let dir = CGVector(dx: sin(r1), dy: -cos(r1))
        let wing = 1.45 * u
        func rotated(_ v: CGVector, _ deg: CGFloat) -> CGVector {
            let t = deg * .pi / 180
            return CGVector(dx: v.dx * cos(t) - v.dy * sin(t), dy: v.dx * sin(t) + v.dy * cos(t))
        }
        let head = CGMutablePath()
        for side in [-1.0, 1.0] as [CGFloat] {
            let w = rotated(CGVector(dx: -dir.dx, dy: -dir.dy), side * 48)
            head.move(to: tip); head.addLine(to: CGPoint(x: tip.x + w.dx * wing, y: tip.y + w.dy * wing))
        }
        return arc.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .union(head.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }
    let upper = arcArrow(from: 188, to: 38)
    let lower = arcArrow(from: 8, to: -142)

    // In the middle: a square turning into a circle (the circle behind, lower right).
    let circle = CGPath(ellipseIn: CGRect(x: P(7.35, 5.75).x, y: P(7.35, 5.75).y, width: 3.0 * u, height: 3.0 * u), transform: nil)
    let square = CGPath(roundedRect: CGRect(x: P(5.7, 7.1).x, y: P(5.7, 7.1).y, width: 3.1 * u, height: 3.1 * u),
                        cornerWidth: 0.85 * u, cornerHeight: 0.85 * u, transform: nil)

    let gray = (c(255, 255, 255, 0.36), c(255, 255, 255, 0.29))
    let white = (c(255, 255, 255, 0.60), c(255, 255, 255, 0.50))
    // The circle sits behind the square: cut away the square plus a thin gap, leaving a crescent.
    let gap = square.copy(strokingWithWidth: 0.55 * u, lineCap: .round, lineJoin: .round, miterLimit: 10).union(square)
    material(circle.subtracting(gap), top: gray.0, bottom: gray.1, shadowAlpha: 0.38)
    material(square, top: white.0, bottom: white.1, shadowAlpha: 0.45)
    material(upper, top: white.0, bottom: white.1, shadowAlpha: 0.45)
    material(lower, top: white.0, bottom: white.1, shadowAlpha: 0.45)

    // Icon rim: light on top, shadow at the bottom.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.addPath(squircle); ctx.setLineWidth(max(1, s * 0.006) * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([c(255, 255, 255, 0.55), c(255, 255, 255, 0), c(0, 0, 0, 0), c(0, 0, 0, 0.35)],
                                [0, 0.3, 0.75, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Very faint grain (material texture), inside the squircle only.
    if px >= 128 {
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        var seed: UInt64 = 0x7E47
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        let dot = max(1, s / 512)
        for _ in 0..<(px * px / 6) {
            let v = rnd()
            ctx.setFillColor(v > 0.5 ? c(255, 255, 255, 0.016) : c(0, 0, 0, 0.016))
            ctx.fill(CGRect(x: rect.minX + rnd() * side, y: rect.minY + rnd() * side, width: dot, height: dot))
        }
        ctx.restoreGState()
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! draw(512).write(to: URL(fileURLWithPath: "\(out)/icon-preview.png"))
