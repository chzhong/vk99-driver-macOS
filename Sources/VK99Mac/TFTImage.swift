import Foundation
import CoreGraphics
import ImageIO

enum TFTImageError: Error, CustomStringConvertible {
    case cannotDecode
    case cannotRender

    var description: String {
        switch self {
        case .cannotDecode: return "Could not decode image"
        case .cannotRender: return "Could not render image"
        }
    }
}

struct TFTImage {
    static let width = 160
    static let height = 96
    static let headerBytes = 256
    static let frameBytes = width * height * 2

    static func packedFrame(at url: URL, duration: UInt8 = 1) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TFTImageError.cannotDecode
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let drawnWidth = CGFloat(image.width) * scale
            let drawnHeight = CGFloat(image.height) * scale
            let rect = CGRect(
                x: (CGFloat(width) - drawnWidth) / 2,
                y: (CGFloat(height) - drawnHeight) / 2,
                width: drawnWidth,
                height: drawnHeight
            )
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        guard rendered else { throw TFTImageError.cannotRender }

        var result = [UInt8](repeating: 0xFF, count: headerBytes + frameBytes)
        result[0] = 1 // one frame
        result[1] = max(duration, 1)
        for index in 0..<(width * height) {
            let source = index * 4
            let r = UInt16(rgba[source])
            let g = UInt16(rgba[source + 1])
            let b = UInt16(rgba[source + 2])
            let rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            let target = headerBytes + index * 2
            result[target] = UInt8(truncatingIfNeeded: rgb565)
            result[target + 1] = UInt8(truncatingIfNeeded: rgb565 >> 8)
        }
        let paddedSize = ((result.count + VK99Transport.outputBytes - 1) / VK99Transport.outputBytes) * VK99Transport.outputBytes
        result += repeatElement(0xFF, count: paddedSize - result.count)
        return result
    }

    static func preview(_ packed: [UInt8]) throws -> CGImage {
        guard packed.count >= headerBytes + frameBytes else { throw TFTImageError.cannotRender }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let source = headerBytes + index * 2
            let pixel = UInt16(packed[source]) | (UInt16(packed[source + 1]) << 8)
            let target = index * 4
            rgba[target] = UInt8((Int((pixel >> 11) & 0x1F) * 255) / 31)
            rgba[target + 1] = UInt8((Int((pixel >> 5) & 0x3F) * 255) / 63)
            rgba[target + 2] = UInt8((Int(pixel & 0x1F) * 255) / 31)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw TFTImageError.cannotRender
        }
        return image
    }

    static func previewPNG(_ packed: [UInt8]) throws -> Data {
        let image = try preview(packed)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw TFTImageError.cannotRender
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TFTImageError.cannotRender }
        return data as Data
    }
}
