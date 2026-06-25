import AppKit

// Alternative FileBullet icon: a white bullet flying diagonally (up-right) with
// dynamic speed lines, on a lilac→blue gradient squircle.

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("rep") }

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// Diagonal axis (bullet flies to the upper-right). u = along axis (+ = nose),
// v = perpendicular. Map (u,v) → canvas around the center.
let center: CGFloat = 512
let c: CGFloat = 0.70710678
func P(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
    NSPoint(x: center + u*c - v*c, y: center + u*c + v*c)
}

// Background squircle, lilac → blue diagonal gradient.
let margin: CGFloat = 70
let bg = NSBezierPath(roundedRect: NSRect(x: margin, y: margin,
                                          width: CGFloat(size) - 2*margin,
                                          height: CGFloat(size) - 2*margin),
                      xRadius: 210, yRadius: 210)
NSGradient(colors: [col(168, 130, 255), col(108, 116, 246), col(58, 86, 245)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: bg, angle: -45)

// Dynamic speed lines trailing behind the bullet (toward lower-left).
NSBezierPath.defaultLineCapStyle = .round
let streaks: [(v: CGFloat, u0: CGFloat, u1: CGFloat, w: CGFloat, a: CGFloat)] = [
    (   0, -250, -470, 28, 0.95),
    (  78, -250, -430, 20, 0.70),
    ( -78, -250, -440, 20, 0.70),
    ( 145, -270, -400, 14, 0.50),
    (-145, -270, -405, 14, 0.50),
]
for s in streaks {
    let line = NSBezierPath()
    line.move(to: P(s.u0, s.v))
    line.line(to: P(s.u1, s.v))
    line.lineWidth = s.w
    line.lineCapStyle = .round
    col(255, 255, 255, s.a).setStroke()
    line.stroke()
}

// Bullet outline in (u,v): rounded base, straight body, ogive nose.
let hw: CGFloat = 92          // half width
let uBase: CGFloat = -265
let uShoulder: CGFloat = 10
let uTip: CGFloat = 270

let bullet = NSBezierPath()
bullet.move(to: P(uShoulder, -hw))
bullet.line(to: P(uBase + 20, -hw))
bullet.curve(to: P(uBase, 0),
             controlPoint1: P(uBase, -hw), controlPoint2: P(uBase, -hw * 0.5))
bullet.curve(to: P(uBase + 20, hw),
             controlPoint1: P(uBase, hw * 0.5), controlPoint2: P(uBase, hw))
bullet.line(to: P(uShoulder, hw))
bullet.curve(to: P(uTip, 0),
             controlPoint1: P(uShoulder + 130, hw), controlPoint2: P(uTip, hw * 0.42))
bullet.curve(to: P(uShoulder, -hw),
             controlPoint1: P(uTip, -hw * 0.42), controlPoint2: P(uShoulder + 130, -hw))
bullet.close()

// Soft shadow for depth.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = col(40, 30, 90, 0.40)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: -12, height: -14)
shadow.set()
col(255, 255, 255, 1).setFill()
bullet.fill()
NSGraphicsContext.restoreGraphicsState()

// White body with a subtle cross-axis gradient for a rounded, metallic feel.
NSGradient(colors: [col(214, 220, 238), col(255, 255, 255), col(224, 229, 244)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: bullet, angle: 45)

// A faint tint line separating nose from body (cannelure), perpendicular to axis.
let band = NSBezierPath()
band.move(to: P(uShoulder, -hw))
band.line(to: P(uShoulder, hw))
band.lineWidth = 10
col(150, 160, 210, 0.45).setStroke()
band.stroke()

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_alt_1024.png"
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
