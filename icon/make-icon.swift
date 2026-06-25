import AppKit

// Renders the FileBullet app icon to a 1024×1024 PNG: a vertical bullet
// (cartridge) — brass case + copper ogive nose — on a blue squircle. Thin
// "document" lines are engraved on the case to hint at files.

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
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

// Horizontal 3-stop "metal cylinder" gradient fill clipped to a path.
func metalFill(_ path: NSBezierPath, _ edge: NSColor, _ light: NSColor) {
    NSGradient(colors: [edge, light, edge], atLocations: [0, 0.46, 1],
               colorSpace: .sRGB)!.draw(in: path, angle: 0)
}

// Background squircle, vertical blue gradient.
let margin: CGFloat = 70
let bg = NSBezierPath(roundedRect: NSRect(x: margin, y: margin,
                                          width: CGFloat(size) - 2*margin,
                                          height: CGFloat(size) - 2*margin),
                      xRadius: 210, yRadius: 210)
NSGradient(colors: [col(255, 255, 255), col(238, 241, 246)])!.draw(in: bg, angle: -90)

// Bullet geometry (origin bottom-left, y points up → bullet points up).
let cx: CGFloat = 512
let halfW: CGFloat = 150
let baseY: CGFloat = 215
let shoulderY: CGFloat = 560
let topY: CGFloat = 840
let rb: CGFloat = 38

// Case: rounded-bottom cylinder from baseY to shoulderY.
let casePath = NSBezierPath()
casePath.move(to: pt(cx - halfW, shoulderY))
casePath.line(to: pt(cx - halfW, baseY + rb))
casePath.appendArc(withCenter: pt(cx - halfW + rb, baseY + rb), radius: rb, startAngle: 180, endAngle: 270)
casePath.line(to: pt(cx + halfW - rb, baseY))
casePath.appendArc(withCenter: pt(cx + halfW - rb, baseY + rb), radius: rb, startAngle: 270, endAngle: 360)
casePath.line(to: pt(cx + halfW, shoulderY))
casePath.close()

// Nose: ogive from the shoulder to a rounded point.
let nose = NSBezierPath()
nose.move(to: pt(cx - halfW, shoulderY))
nose.line(to: pt(cx + halfW, shoulderY))
nose.curve(to: pt(cx, topY),
           controlPoint1: pt(cx + halfW, shoulderY + (topY - shoulderY) * 0.5),
           controlPoint2: pt(cx + halfW * 0.55, topY))
nose.curve(to: pt(cx - halfW, shoulderY),
           controlPoint1: pt(cx - halfW * 0.55, topY),
           controlPoint2: pt(cx - halfW, shoulderY + (topY - shoulderY) * 0.5))
nose.close()

// Soft drop shadow behind the whole bullet.
let silhouette = casePath.copy() as! NSBezierPath
silhouette.append(nose)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = col(90, 100, 120, 0.35)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
col(0, 0, 0, 0.001).setFill()
silhouette.fill()
NSGraphicsContext.restoreGraphicsState()

// Fill case (brass) and nose (copper) with cylindrical metal gradients.
metalFill(casePath, col(150, 104, 18), col(247, 214, 112))
metalFill(nose, col(165, 74, 18), col(255, 181, 74))

// Cannelure groove just under the shoulder.
let groove = NSBezierPath(roundedRect: NSRect(x: cx - halfW, y: shoulderY - 60,
                                              width: 2 * halfW, height: 20),
                          xRadius: 10, yRadius: 10)
col(120, 82, 12, 0.55).setFill()
groove.fill()

// "Document" lines engraved on the case body.
col(255, 255, 255, 0.45).setFill()
for i in 0..<3 {
    let y = shoulderY - 140 - CGFloat(i) * 78
    let w = 2 * halfW - 90
    NSBezierPath(roundedRect: NSRect(x: cx - w/2, y: y, width: w, height: 22),
                 xRadius: 11, yRadius: 11).fill()
}

// Base rim (slightly darker band at the very bottom).
let rim = NSBezierPath(roundedRect: NSRect(x: cx - halfW, y: baseY, width: 2 * halfW, height: 34),
                       xRadius: rb, yRadius: rb)
col(120, 82, 12, 0.5).setFill()
rim.fill()

// Crisp outline around the bullet.
silhouette.lineWidth = 5
col(120, 90, 30, 0.35).setStroke()
silhouette.stroke()

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
