import AppKit
let image = NSImage(size: NSSize(width: 680, height: 520))
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 680, height: 520)).fill()
func text(_ value: String, _ size: CGFloat, _ y: CGFloat, _ color: NSColor, bold: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: (680-width)/2, y: y), withAttributes: attributes)
}
text("MyPLaMo for Mac", 28, 449, NSColor(calibratedWhite: 0.15, alpha: 1), bold: true)
text("アプリを「アプリケーション」へドラッグ", 16, 417, .darkGray)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 304, y: 330)); arrow.line(to: NSPoint(x: 369, y: 330))
arrow.move(to: NSPoint(x: 352, y: 346)); arrow.line(to: NSPoint(x: 369, y: 330)); arrow.line(to: NSPoint(x: 352, y: 314))
arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.62, alpha: 1).setStroke(); arrow.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
