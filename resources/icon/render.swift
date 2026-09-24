import AppKit

let canvas: CGFloat = 1024
let box: CGFloat = 824          // Apple's macOS icon grid: rounded rect ~824 px in a 1024 canvas
let radius: CGFloat = 185

func hex(_ v: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func background(_ top: NSColor, _ bottom: NSColor) -> CGRect {
    let inset = (canvas - box) / 2
    let rect = CGRect(x: inset, y: inset, width: box, height: box)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)
    // soft top highlight
    let hl = NSGradient(starting: NSColor(white: 1, alpha: 0.22), ending: NSColor(white: 1, alpha: 0))!
    hl.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rect
}

func stroke(_ p: NSBezierPath, _ w: CGFloat) {
    p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round
    NSColor.white.setStroke(); p.stroke()
}

// Microphone glyph: capsule head, U-shaped cradle, stem and base.
func mic(cx: CGFloat, cy: CGFloat, scale: CGFloat = 1) {
    let s = scale
    NSColor.white.setFill()
    let head = CGRect(x: cx - 95 * s, y: cy + 60 * s - 170 * s, width: 190 * s, height: 340 * s)
    NSBezierPath(roundedRect: head, xRadius: 95 * s, yRadius: 95 * s).fill()
    let cradle = NSBezierPath()
    cradle.appendArc(withCenter: CGPoint(x: cx, y: cy + 20 * s), radius: 190 * s, startAngle: 180, endAngle: 360, clockwise: false)
    stroke(cradle, 56 * s)
    let stem = NSBezierPath()
    stem.move(to: CGPoint(x: cx, y: cy + 20 * s - 190 * s)); stem.line(to: CGPoint(x: cx, y: cy - 250 * s))
    stroke(stem, 56 * s)
    let base = NSBezierPath()
    base.move(to: CGPoint(x: cx - 120 * s, y: cy - 250 * s)); base.line(to: CGPoint(x: cx + 120 * s, y: cy - 250 * s))
    stroke(base, 56 * s)
}

// Waveform: rounded bars.
func bars(cx: CGFloat, cy: CGFloat, heights: [CGFloat], width: CGFloat, gap: CGFloat) {
    NSColor.white.setFill()
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    var x = cx - total / 2
    for h in heights {
        NSBezierPath(roundedRect: CGRect(x: x, y: cy - h / 2, width: width, height: h), xRadius: width / 2, yRadius: width / 2).fill()
        x += width + gap
    }
}

func render(_ name: String, _ draw: () -> Void) {
    let img = NSImage(size: NSSize(width: canvas, height: canvas))
    img.lockFocus()
    draw()
    img.unlockFocus()
    let tiff = img.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(name).png"))
}

let c = canvas / 2
render("A-ocean-mic") { let r = background(hex(0x3B8BFF), hex(0x0B3D9E)); _ = r; mic(cx: c, cy: c) }
render("B-graphite-wave") { _ = background(hex(0x4A4A4E), hex(0x1C1C1E)); bars(cx: c, cy: c, heights: [150, 290, 440, 290, 150], width: 66, gap: 42) }
render("C-coral-mic") { _ = background(hex(0xFF8A5C), hex(0xD9302F)); mic(cx: c, cy: c) }
render("D-mint-mic-wave") {
    _ = background(hex(0x3ED8A4), hex(0x0B7F63))
    mic(cx: c, cy: c + 10, scale: 0.86)
    bars(cx: c - 250, cy: c + 40, heights: [90, 170, 110], width: 44, gap: 30)
    bars(cx: c + 250, cy: c + 40, heights: [110, 170, 90], width: 44, gap: 30)
}
render("E-indigo-wave-mic") {
    _ = background(hex(0x7C6CFF), hex(0x3B2FB8))
    bars(cx: c, cy: c + 70, heights: [120, 230, 360, 230, 120], width: 60, gap: 38)
    // small stand under the waveform so it still reads as a microphone
    let stem = NSBezierPath(); stem.move(to: CGPoint(x: c, y: c - 130)); stem.line(to: CGPoint(x: c, y: c - 250)); stroke(stem, 56)
    let base = NSBezierPath(); base.move(to: CGPoint(x: c - 120, y: c - 250)); base.line(to: CGPoint(x: c + 120, y: c - 250)); stroke(base, 56)
}

// Preview sheet: each candidate on a light and a dark row, plus a 32 px Dock/Finder-size version.
let names = ["A-ocean-mic", "B-graphite-wave", "C-coral-mic", "D-mint-mic-wave", "E-indigo-wave-mic"]
let cell: CGFloat = 300, rows: CGFloat = 2
let sheet = NSImage(size: NSSize(width: cell * CGFloat(names.count), height: cell * rows + 60))
sheet.lockFocus()
for (row, bg) in [(0, hex(0xF2F2F7)), (1, hex(0x1C1C1E))] {
    let y = cell * CGFloat(1 - row) + 60
    bg.setFill(); NSBezierPath(rect: CGRect(x: 0, y: y, width: cell * CGFloat(names.count), height: cell)).fill()
    for (i, n) in names.enumerated() {
        let img = NSImage(contentsOfFile: "\(n).png")!
        let x = CGFloat(i) * cell
        img.draw(in: CGRect(x: x + 40, y: y + 60, width: 220, height: 220))
        img.draw(in: CGRect(x: x + 20, y: y + 20, width: 32, height: 32))   // Finder list size
        img.draw(in: CGRect(x: x + 60, y: y + 12, width: 48, height: 48))   // Dock-ish size
    }
}
hex(0xFFFFFF).setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: cell * CGFloat(names.count), height: 60)).fill()
for (i, n) in names.enumerated() {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black]
    (n as NSString).draw(at: CGPoint(x: CGFloat(i) * cell + 40, y: 18), withAttributes: attrs)
}
sheet.unlockFocus()
let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "preview.png"))
print("rendered \(names.count) candidates + preview.png")
