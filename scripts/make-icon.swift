import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: make-icon.swift INPUT.png OUTPUT.iconset\n", stderr)
    exit(2)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fputs("Could not load icon source\n", stderr)
    exit(1)
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in sizes {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    let bitmap = pixels.withUnsafeMutableBytes { raw -> CGImage? in
        guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
    guard let bitmap else {
        fputs("Could not render icon size \(size)\n", stderr)
        exit(1)
    }
    let path = output.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("Could not write \(path.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("Could not finalize \(path.path)\n", stderr)
        exit(1)
    }
}
