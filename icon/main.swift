// icon/main.swift — 生成 1024x1024 应用图标 PNG
// 设计：夜空蓝渐变圆角方 + 两块屏幕 + 中间同步链接环（与菜单栏图标同一语言）
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon-1024.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("bitmap alloc failed\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// ---- 背景：圆角方 + 渐变
let radius: CGFloat = 230
let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
ctx.saveGState()
bgPath.addClip()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.30, blue: 0.53, alpha: 1),   // 上：亮蓝
    NSColor(srgbRed: 0.07, green: 0.13, blue: 0.27, alpha: 1),   // 下：深靛
])!
gradient.draw(in: bgRect, angle: -90)

// 顶部柔光
let glow = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.18),
    NSColor(white: 1.0, alpha: 0.0),
])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 140, y: 480, width: 744, height: 640)),
          relativeCenterPosition: NSPoint(x: 0, y: 0.25))

// 底部一点点亮（避免死黑）
let bottom = NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.45, blue: 0.80, alpha: 0.18),
    NSColor(srgbRed: 0.20, green: 0.45, blue: 0.80, alpha: 0.0),
])!
bottom.draw(in: NSBezierPath(ovalIn: NSRect(x: 100, y: -160, width: 824, height: 420)), angle: 90)
ctx.restoreGState()

// ---- 两块屏幕（横向显示器）
let white = NSColor(white: 1.0, alpha: 0.97)
let screenFill = NSColor(white: 1.0, alpha: 0.10)
let lw: CGFloat = 26

func screenPath(_ x: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: 388, width: 330, height: 258),
                 xRadius: 40, yRadius: 40)
}
for x in [118.0, 576.0] as [CGFloat] {
    let p = screenPath(x)
    p.lineWidth = lw
    screenFill.setFill()
    p.fill()
    white.setStroke()
    p.stroke()
}

// ---- 中间链接（胶囊 + 中心环）
let bar = NSBezierPath(roundedRect: NSRect(x: 428, y: 502, width: 168, height: 28),
                       xRadius: 14, yRadius: 14)
white.setFill()
bar.fill()

let ringOuter = NSBezierPath(ovalIn: NSRect(x: 512 - 46, y: 516 - 46, width: 92, height: 92))
white.setFill()
ringOuter.fill()
let ringInner = NSBezierPath(ovalIn: NSRect(x: 512 - 22, y: 516 - 22, width: 44, height: 44))
NSColor(srgbRed: 0.10, green: 0.20, blue: 0.38, alpha: 1).setFill()
ringInner.fill()

// ---- 屏幕里的“内容”小条（暗示有画面）
let barFill = NSColor(white: 1.0, alpha: 0.45)
for x in [118.0, 576.0] as [CGFloat] {
    for (i, w) in [180.0, 128.0, 152.0].enumerated() {
        let r = NSRect(x: x + 52, y: 536 - CGFloat(i) * 46, width: CGFloat(w), height: 16)
        barFill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()

// ---- 输出 PNG
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
