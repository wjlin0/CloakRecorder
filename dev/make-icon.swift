import AppKit
import CoreGraphics
import Foundation

// 渲染 CloakRecorder 应用图标（"录屏 + 隐身"）：渐变圆角矩形 +
// 白色取景框 + 红色录制圆点 + 斜向磨砂"隐身"条纹。
// 输出一张 1024×1024 的 PNG（后续由 iconutil 缩放成 .icns）。

let size = 1024
let s = CGFloat(size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("无法创建位图") }
rep.size = NSSize(width: s, height: s)

NSGraphicsContext.saveGraphicsState()
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无上下文") }
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// 1. 圆角矩形（近似 squircle）背景
let corner = s * 0.2257
let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let cs = CGColorSpaceCreateDeviceRGB()
let cols = [
    CGColor(srgbRed: 0.30, green: 0.24, blue: 0.90, alpha: 1.0), // indigo
    CGColor(srgbRed: 0.62, green: 0.34, blue: 0.95, alpha: 1.0), // purple
    CGColor(srgbRed: 0.86, green: 0.42, blue: 0.88, alpha: 1.0), // pink-violet
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: cols, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// 2. 白色取景框（半透明屏幕表面）
let screenW = s * 0.60
let screenH = s * 0.44
let screenRect = CGRect(x: (s - screenW) / 2, y: (s - screenH) / 2 + s * 0.02, width: screenW, height: screenH)
let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenW * 0.14, cornerHeight: screenW * 0.14, transform: nil)

// 屏幕底（柔和白）
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
ctx.addPath(screenPath)
ctx.fillPath()
// 屏幕高光边框
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
ctx.setLineWidth(s * 0.012)
ctx.addPath(screenPath)
ctx.strokePath()

// 3. 红色录制圆点（带白色外环）
let dotD = screenH * 0.34
let dotRect = CGRect(
    x: screenRect.minX + screenW * 0.16 - dotD / 2,
    y: screenRect.midY - dotD / 2,
    width: dotD, height: dotD)
ctx.setFillColor(CGColor(srgbRed: 1.00, green: 0.24, blue: 0.30, alpha: 0.96))
ctx.fillEllipse(in: dotRect)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75))
ctx.setLineWidth(dotD * 0.09)
ctx.strokeEllipse(in: dotRect.insetBy(dx: -dotD * 0.12, dy: -dotD * 0.12))

// 4. 斜向磨砂"隐身/隐身"条纹（只在取景框内）
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
ctx.translateBy(x: s / 2, y: s / 2)
ctx.rotate(by: -0.42)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.26))
let stripeW = s * 0.045
let stripeH = s * 1.6
for i in 0..<3 {
    let x = CGFloat(i) * s * 0.20 - s * 0.40
    ctx.fill(CGRect(x: x, y: -stripeH / 2, width: stripeW, height: stripeH))
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("无法编码 PNG") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! data.write(to: URL(fileURLWithPath: out))
print("写出图标: \(out)")