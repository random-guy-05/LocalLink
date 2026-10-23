import AppKit

let size = NSSize(width: 760, height: 440)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.084, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
let mint = NSColor(calibratedRed: 0.49, green: 0.91, blue: 0.79, alpha: 1)
let secondary = NSColor(calibratedRed: 0.60, green: 0.66, blue: 0.73, alpha: 1)
text("LocalLink", x: 46, y: 356, size: 35, color: .white, weight: .semibold)
text("Your Mac. Wherever you are.", x: 47, y: 323, size: 15, color: secondary)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 338, y: 216)); arrow.line(to: NSPoint(x: 422, y: 216))
arrow.move(to: NSPoint(x: 408, y: 230)); arrow.line(to: NSPoint(x: 422, y: 216)); arrow.line(to: NSPoint(x: 408, y: 202))
arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
mint.setStroke(); arrow.stroke()
text("Drag LocalLink to Applications", x: 258, y: 108, size: 14, color: mint, weight: .medium)
text("macOS 14+  •  Intel & Apple Silicon  •  Preview release", x: 47, y: 39, size: 11, color: secondary)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
