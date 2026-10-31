import AppKit
import CoreGraphics
import CoreImage

// MARK: - Pixel format

/// Premultiplied RGBA, 8 bits per component, byte order as stored in memory.
enum PixelFormat {
    static let bitsPerComponent = 8
    static let componentsPerPixel = 4
    static let bytesPerPixel = 4
    static let bitmapInfo: CGBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

/// Core Graphics draws images "y-up", but PaintCraft rasters keep a top-left
/// (y-down) coordinate system. Drawing a CGImage into one of those flipped
/// contexts without compensation mirrors it vertically, so all image draws go
/// through this helper.
enum CGImageDrawing {
    static func drawUpright(_ image: CGImage, in rect: CGRect, into ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}

func makeColorSpace() -> CGColorSpace {
    // Broad device-friendly sRGB; documented as the app's single working color space.
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

// MARK: - Color helpers

struct PixelColor: Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    static let clear = PixelColor(r: 0, g: 0, b: 0, a: 0)
    static let black = PixelColor(r: 0, g: 0, b: 0, a: 255)
    static let white = PixelColor(r: 255, g: 255, b: 255, a: 255)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 {
            guard let v = UInt32(s, radix: 16) else { return nil }
            self.init(r: UInt8((v >> 24) & 0xFF), g: UInt8((v >> 16) & 0xFF),
                      b: UInt8((v >> 8) & 0xFF), a: UInt8(v & 0xFF))
        } else if s.count == 6 {
            guard let v = UInt32(s, radix: 16) else { return nil }
            self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF),
                      b: UInt8(v & 0xFF), a: 255)
        } else {
            return nil
        }
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Premultiplies RGB for storage in a premultiplied-alpha bitmap.
    var premultiplied: (UInt8, UInt8, UInt8, UInt8) {
        if a == 255 { return (r, g, b, 255) }
        if a == 0 { return (0, 0, 0, 0) }
        let af = Double(a) / 255.0
        return (UInt8((Double(r) * af).rounded()),
                UInt8((Double(g) * af).rounded()),
                UInt8((Double(b) * af).rounded()),
                a)
    }

    func withAlpha(_ alpha: UInt8) -> PixelColor {
        PixelColor(r: r, g: g, b: b, a: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0, alpha: CGFloat(a) / 255.0)
    }

    var cgColor: CGColor {
        nsColor.cgColor
    }

    static func from(_ color: NSColor) -> PixelColor {
        guard let c = color.usingColorSpace(.sRGB) else {
            return PixelColor(r: 0, g: 0, b: 0, a: 255)
        }
        return PixelColor(
            r: UInt8(clamping: Int((c.redComponent * 255).rounded())),
            g: UInt8(clamping: Int((c.greenComponent * 255).rounded())),
            b: UInt8(clamping: Int((c.blueComponent * 255).rounded())),
            a: UInt8(clamping: Int((c.alphaComponent * 255).rounded()))
        )
    }

    // MARK: Composition (unpremultiplied "over")

    static func over(_ src: PixelColor, _ dst: PixelColor) -> PixelColor {
        if src.a == 255 { return src }
        if src.a == 0 { return dst }
        let sa = Double(src.a) / 255.0
        let da = Double(dst.a) / 255.0
        let oa = sa + da * (1.0 - sa)
        if oa <= 0.0001 { return .clear }
        func ch(_ s: UInt8, _ d: UInt8) -> UInt8 {
            let v = (Double(s) * sa + Double(d) * da * (1.0 - sa)) / oa
            return UInt8(clamping: Int(v.rounded()))
        }
        return PixelColor(r: ch(src.r, dst.r), g: ch(src.g, dst.g),
                          b: ch(src.b, dst.b), a: UInt8(clamping: Int((oa * 255).rounded())))
    }

    static func lerp(_ a: PixelColor, _ b: PixelColor, t: Double) -> PixelColor {
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(x) + (Double(y) - Double(x)) * t).rounded()))
        }
        return PixelColor(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: ch(a.a, b.a))
    }
}

// MARK: - Raster: one bitmap layer of pixels

/// A single RGBA8 bitmap. All tools draw into a Raster through its `CGContext`,
/// which keeps drawing code simple while retaining fast raw pixel access for
/// flood fill, color replacement, background removal and filters.
final class Raster {
    let width: Int
    let height: Int
    let stride: Int
    let data: UnsafeMutablePointer<UInt8>
    let bitmapContext: CGContext
    let colorSpace: CGColorSpace

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.stride = self.width * PixelFormat.bytesPerPixel
        self.data = UnsafeMutablePointer<UInt8>.allocate(capacity: self.stride * self.height)
        self.data.initialize(repeating: 0, count: self.stride * self.height)
        self.colorSpace = makeColorSpace()
        self.bitmapContext = CGContext(
            data: self.data,
            width: self.width,
            height: self.height,
            bitsPerComponent: PixelFormat.bitsPerComponent,
            bytesPerRow: self.stride,
            space: self.colorSpace,
            bitmapInfo: PixelFormat.bitmapInfo.rawValue
        )!
        // Core Graphics origin bottom-left; Paint's coordinate space is top-left.
        // Tools work in top-left space, so flip the context up front.
        self.bitmapContext.translateBy(x: 0, y: CGFloat(self.height))
        self.bitmapContext.scaleBy(x: 1, y: -1)
    }

    deinit {
        data.deallocate()
    }

    // MARK: Pixel access (top-left origin, x0..<width, y0..<height)

    @inline(__always)
    func index(_ x: Int, _ y: Int) -> Int {
        y * stride + x * PixelFormat.bytesPerPixel
    }

    @inline(__always)
    func getPixel(_ x: Int, _ y: Int) -> PixelColor {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        let i = index(x, y)
        return PixelColor(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
    }

    @inline(__always)
    func setPixel(_ x: Int, _ y: Int, _ c: PixelColor) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = index(x, y)
        data[i] = c.r; data[i + 1] = c.g; data[i + 2] = c.b; data[i + 3] = c.a
    }

    @inline(__always)
    func setPixelPremultiplied(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = index(x, y)
        data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = c.3
    }

    func clear() {
        data.update(repeating: 0, count: stride * height)
    }

    func clear(rect: CGRect) {
        let r = clampRect(rect)
        if r.isEmpty { return }
        bitmapContext.clear(r)
    }

    func fill(_ color: PixelColor) {
        let p = color.premultiplied
        var i = 0
        while i < stride * height {
            data[i] = p.0; data[i + 1] = p.1; data[i + 2] = p.2; data[i + 3] = p.3
            i += 4
        }
    }

    func fill(rect: CGRect, with color: PixelColor) {
        let r = clampRect(rect)
        if r.isEmpty { return }
        let p = color.premultiplied
        let x0 = Int(r.minX), y0 = Int(r.minY)
        let x1 = Int(r.maxX), y1 = Int(r.maxY)
        for y in y0..<y1 {
            var i = index(x0, y)
            for _ in x0..<x1 {
                data[i] = p.0; data[i + 1] = p.1; data[i + 2] = p.2; data[i + 3] = p.3
                i += 4
            }
        }
    }

    func copyPixels(from other: Raster) {
        let h = Swift.min(height, other.height)
        let w = Swift.min(width, other.width)
        for y in 0..<h {
            memcpy(data + y * stride, other.data + y * other.stride, w * PixelFormat.bytesPerPixel)
        }
    }

    // MARK: Geometry helpers

    func clampRect(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // MARK: Conversion

    func makeImage() -> CGImage? {
        bitmapContext.makeImage()
    }

    func snapshot() -> Raster {
        let copy = Raster(width: width, height: height)
        memcpy(copy.data, data, stride * height)
        return copy
    }

    /// Replaces this raster's contents with another raster of the same size.
    func replaceContents(with other: Raster) {
        if other.width == width && other.height == height {
            memcpy(data, other.data, stride * height)
        } else {
            clear()
            if let img = other.makeImage() {
                CGImageDrawing.drawUpright(img, in: bounds, into: bitmapContext)
            }
        }
    }

    /// Draw another raster scaled into this raster's bounds.
    func draw(_ other: Raster, in rect: CGRect) {
        guard let img = other.makeImage() else { return }
        bitmapContext.saveGState()
        bitmapContext.interpolationQuality = .high
        CGImageDrawing.drawUpright(img, in: rect, into: bitmapContext)
        bitmapContext.restoreGState()
    }

    /// Creates a raster resized to new dimensions using CG interpolation.
    func resized(to newWidth: Int, newHeight: Int, interpolation: CGInterpolationQuality = .high) -> Raster {
        let out = Raster(width: newWidth, height: newHeight)
        guard let img = makeImage() else { return out }
        out.bitmapContext.saveGState()
        out.bitmapContext.interpolationQuality = interpolation
        CGImageDrawing.drawUpright(img, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight),
                                   into: out.bitmapContext)
        out.bitmapContext.restoreGState()
        return out
    }

    /// Returns cropped copy in top-left coordinates.
    func cropped(_ rect: CGRect) -> Raster {
        let r = CGRect(x: rect.origin.x, y: rect.origin.y,
                       width: rect.width, height: rect.height).integral
        let out = Raster(width: Int(r.width), height: Int(r.height))
        guard let img = makeImage(), let sub = img.cropping(to: r) else { return out }
        out.bitmapContext.saveGState()
        CGImageDrawing.drawUpright(sub, in: CGRect(x: 0, y: 0, width: Int(r.width), height: Int(r.height)),
                                   into: out.bitmapContext)
        out.bitmapContext.restoreGState()
        return out
    }

    /// Horizontal/vertical flip in place (deterministic pixel mapping).
    func flipHorizontally() {
        let out = Raster(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                out.setPixel(x, y, getPixel(width - 1 - x, y))
            }
        }
        replaceContents(with: out)
    }

    func flipVertically() {
        let out = Raster(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                out.setPixel(x, y, getPixel(x, height - 1 - y))
            }
        }
        replaceContents(with: out)
    }

    /// Rotates 90 degrees clockwise: (x,y) -> (H-1-y, x). Dimensions swap.
    func rotate90Clockwise() -> Raster {
        let out = Raster(width: height, height: width)
        for ny in 0..<out.height {
            for nx in 0..<out.width {
                out.setPixel(nx, ny, getPixel(ny, height - 1 - nx))
            }
        }
        return out
    }

    /// Rotates 90 degrees counter-clockwise: (x,y) -> (y, W-1-x). Dimensions swap.
    func rotate90CounterClockwise() -> Raster {
        let out = Raster(width: height, height: width)
        for ny in 0..<out.height {
            for nx in 0..<out.width {
                out.setPixel(nx, ny, getPixel(width - 1 - ny, nx))
            }
        }
        return out
    }

    func rotate180() -> Raster {
        let out = Raster(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                out.setPixel(x, y, getPixel(width - 1 - x, height - 1 - y))
            }
        }
        return out
    }

    /// Converts premultiplied storage into straight RGBA `Data` for PNG writing.
    func rgbaData() -> Data {
        var out = Data(capacity: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let c = getPixel(x, y)
                out.append(c.r); out.append(c.g); out.append(c.b); out.append(c.a)
            }
        }
        return out
    }

    func hash(rect: CGRect) -> Int {
        let r = clampRect(rect)
        var h = Hasher()
        let x0 = Int(r.minX), x1 = Int(min(r.maxX, CGFloat(width)))
        let y0 = Int(r.minY), y1 = Int(min(r.maxY, CGFloat(height)))
        for y in y0..<y1 {
            let rowStart = index(max(x0, 0), y)
            let rowEnd = x1 > 0 ? index(x1 - 1, y) + 4 : rowStart
            if rowEnd > rowStart {
                data.advanced(by: rowStart).withMemoryRebound(to: UInt8.self, capacity: rowEnd - rowStart) { ptr in
                    h.combine(bytes: UnsafeRawBufferPointer(start: ptr, count: rowEnd - rowStart))
                }
            }
        }
        return h.finalize()
    }
}
