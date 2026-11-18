import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WorkspaceHelper.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let images: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in images {
    let image = makeIcon(pixels: pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("無法產生 \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }

func makeIcon(pixels: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(dx: pixels * 0.04, dy: pixels * 0.04)
    let background = NSBezierPath(roundedRect: bounds, xRadius: pixels * 0.22, yRadius: pixels * 0.22)
    NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.95, alpha: 1).setFill()
    background.fill()

    let configuration = NSImage.SymbolConfiguration(pointSize: pixels * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let side = pixels * 0.52
        let frame = NSRect(
            x: (pixels - side) / 2,
            y: (pixels - side) / 2,
            width: side,
            height: side
        )
        symbol.draw(in: frame)
    }
    image.unlockFocus()
    return image
}
