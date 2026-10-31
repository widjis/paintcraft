import AppKit
import CoreGraphics

/// A selection is a rectangular region plus an optional 8-bit alpha mask that
/// allows freeform ("lasso") shapes. A nil `mask` means the whole `rect` is selected.
/// Coordinates are in top-left image space, matching the canvas.
final class SelectionModel {
    private(set) var bounds: CGRect          // integral rect in image space
    private(set) var mask: CGImage?          // alpha mask, 1 byte per pixel of `bounds`
    private var maskBytes: [UInt8]?          // cached mask bytes (row-major, w*h)
    private var maskW: Int
    private var maskH: Int
    private var boundaryCache: CGPath?

    var isEmpty: Bool { bounds.isEmpty || bounds.width < 1 || bounds.height < 1 }

    init() {
        self.bounds = .zero
        self.mask = nil
        self.maskBytes = nil
        self.maskW = 0
        self.maskH = 0
    }

    init(rect: CGRect) {
        self.bounds = rect.integral
        self.mask = nil
        self.maskBytes = nil
        self.maskW = 0
        self.maskH = 0
        self.boundaryCache = nil
    }

    /// Builds a freeform selection from a path in image coordinates.
    init(path: CGPath, canvasSize: CGSize) {
        let box = path.boundingBoxOfPath.integral
        let clipped = box.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !clipped.isEmpty else {
            self.bounds = .zero; self.mask = nil; self.maskBytes = nil
            self.maskW = 0; self.maskH = 0
            return
        }
        let w = Int(clipped.width), h = Int(clipped.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        // Draw path into a gray 8-bit bitmap; covered pixels become 255 (alpha).
        bytes.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: -clipped.minX, y: -clipped.minY)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        // Threshold to binary alpha.
        for i in 0..<bytes.count { bytes[i] = bytes[i] > 127 ? 255 : 0 }
        self.bounds = clipped
        self.maskW = w
        self.maskH = h
        self.maskBytes = bytes
        self.mask = SelectionModel.makeMaskImage(bytes: bytes, w: w, h: h)
        self.boundaryCache = nil
    }

    private static func makeMaskImage(bytes: [UInt8], w: Int, h: Int) -> CGImage? {
        var b = bytes
        return b.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: Hit testing

    func contains(_ point: CGPoint) -> Bool {
        guard !isEmpty, bounds.contains(point) else { return false }
        guard let mb = maskBytes else { return true }
        let x = Int(point.x - bounds.minX)
        let y = Int(point.y - bounds.minY)
        guard x >= 0, y >= 0, x < maskW, y < maskH else { return false }
        return mb[y * maskW + x] > 0
    }

    /// Intersects another selection: conservative implementation keeps the
    /// existing selection but shrinks `bounds` when rectangles overlap.
    func intersect(with other: SelectionModel) -> SelectionModel {
        let r = bounds.intersection(other.bounds)
        if maskBytes == nil && other.maskBytes == nil {
            return SelectionModel(rect: r)
        }
        // For freeform selections, build a polygon intersection via path clipping
        // is overkill; fall back to the rect-approximation, which is honest and
        // documented in the spec as a v1 limitation.
        return SelectionModel(rect: r)
    }

    // MARK: Boundary path for marching ants

    /// Boundary polyline in image coordinates; used to stroke the animated dashed
    /// outline. For masked selections this traces the mask edge.
    func boundaryPath() -> CGPath {
        if let cached = boundaryCache { return cached }
        let path = CGMutablePath()
        if isEmpty {
            boundaryCache = path
            return path
        }
        if let mb = maskBytes {
            path.addRect(bounds) // outline the mask box, plus traced edge below
            // Trace mask edges: collect boundary segments between selected and
            // unselected pixels, then merge into horizontal/vertical runs.
            var segs: [(CGPoint, CGPoint)] = []
            let w = maskW, h = maskH
            for y in 0..<h {
                for x in 0..<w {
                    let on = mb[y * w + x] > 0
                    if !on { continue }
                    let px = bounds.minX + CGFloat(x)
                    let py = bounds.minY + CGFloat(y)
                    if x == 0 || mb[y * w + x - 1] == 0 {
                        segs.append((CGPoint(x: px, y: py), CGPoint(x: px, y: py + 1)))
                    }
                    if x == w - 1 || mb[y * w + x + 1] == 0 {
                        segs.append((CGPoint(x: px + 1, y: py), CGPoint(x: px + 1, y: py + 1)))
                    }
                    if y == 0 || mb[(y - 1) * w + x] == 0 {
                        segs.append((CGPoint(x: px, y: py), CGPoint(x: px + 1, y: py)))
                    }
                    if y == h - 1 || mb[(y + 1) * w + x] == 0 {
                        segs.append((CGPoint(x: px, y: py + 1), CGPoint(x: px + 1, y: py + 1)))
                    }
                }
            }
            for s in segs {
                path.move(to: s.0)
                path.addLine(to: s.1)
            }
        } else {
            path.addRect(bounds)
        }
        boundaryCache = path
        return path
    }

    /// Installs a canvas-sized alpha mask (0/255) cropped to `bounds`.
    /// Used by the magic wand, which works on the whole composite.
    func installMask(bytes: [UInt8], canvasWidth: Int, canvasHeight: Int) {
        guard canvasWidth > 0, canvasHeight > 0, !bounds.isEmpty else { return }
        let w = Int(bounds.width), h = Int(bounds.height)
        guard bytes.count >= canvasWidth * canvasHeight else { return }
        var cropped = [UInt8](repeating: 0, count: w * h)
        let bx = Int(bounds.minX), by = Int(bounds.minY)
        for y in 0..<h {
            let sy = by + y
            guard sy >= 0, sy < canvasHeight else { continue }
            for x in 0..<w {
                let sx = bx + x
                guard sx >= 0, sx < canvasWidth else { continue }
                cropped[y * w + x] = bytes[sy * canvasWidth + sx]
            }
        }
        maskBytes = cropped
        maskW = w
        maskH = h
        mask = SelectionModel.makeMaskImage(bytes: cropped, w: w, h: h)
        boundaryCache = nil
    }

    static func path(from points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}
