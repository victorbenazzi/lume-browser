import AppKit
import ImageIO
import UniformTypeIdentifiers

// Icon Composer renders the material; this step supplies the legacy macOS
// canvas, optical margin, shadow and each required ICNS representation.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: build-icon.swift <rendered-1024.png> <output-directory>")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == 1024, artwork.height == 1024,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Expected a 1024 x 1024 icon render in PNG format")
}
let iconset = output.appendingPathComponent("Lume.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let representations = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                       (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in representations {
    let pixels = points * scale
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create icon canvas")
    }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
                      color: CGColor(gray: 0, alpha: 0.22))
    context.draw(artwork, in: CGRect(x: 100, y: 100, width: 824, height: 824))
    guard let image = context.makeImage() else { fatalError("Cannot render icon") }
    let suffix = scale == 2 ? "@2x" : ""
    let destinationURL = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("Cannot write icon representation") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finish PNG") }
}
