import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum FileIOError: LocalizedError {
    case notAnImage
    case badDocument(String)
    case bitmapTooLarge
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "The file is not a supported image."
        case .badDocument(let why): return "Corrupt PaintCraft document: \(why)."
        case .bitmapTooLarge: return "The image dimensions are too large."
        case .writeFailed(let why): return "Could not write the file: \(why)."
        }
    }
}

/// Document metadata stored in `.paintcraft` files.
private struct DocumentMeta: Codable {
    struct LayerMeta: Codable {
        var name: String
        var isVisible: Bool
        var opacity: Double
        var blendMode: String
        var isLocked: Bool
        var adjustments: [AdjustmentMeta]
        var pngLength: Int
    }
    struct AdjustmentMeta: Codable {
        var kind: String
        var amount: Double
        var amount2: Double
        var enabled: Bool
    }
    var version: Int
    var width: Int
    var height: Int
    var activeLayerIndex: Int
    var layers: [LayerMeta]
}

/// All document and image persistence. The native format is a single flat file:
/// magic, version, JSON metadata, then concatenated PNG blobs per layer.
enum FileIO {
    static let fileExtension = "paintcraft"
    private static let magic: [UInt8] = Array("PCRA".utf8)
    private static let formatVersion = 1

    static var readableTypes: [UTType] {
        [UTType(filenameExtension: fileExtension) ?? .data, .png, .jpeg, .tiff, .bmp, .gif]
    }

    // MARK: Open

    /// Returns the opened document plus non-fatal warnings (e.g. dropped layers).
    static func open(url: URL) throws -> (Document, [String]) {
        let ext = url.pathExtension.lowercased()
        if ext == fileExtension {
            return try openPaintCraft(url: url)
        }
        if ext == "bmp" {
            let raster = try BMPCodec.decode(url: url)
            let doc = Document(image: try imageFrom(raster: raster))
            doc.fileURL = url
            doc.documentName = url.deletingPathExtension().lastPathComponent
            doc.dirty = false
            return (doc, [])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FileIOError.notAnImage
        }
        let doc = Document(image: image)
        doc.fileURL = url
        doc.documentName = url.deletingPathExtension().lastPathComponent
        doc.dirty = false
        return (doc, [])
    }

    private static func imageFrom(raster: Raster) throws -> CGImage {
        guard let image = raster.makeImage() else { throw FileIOError.notAnImage }
        return image
    }

    private static func openPaintCraft(url: URL) throws -> (Document, [String]) {
        guard let data = try? Data(contentsOf: url) else {
            throw FileIOError.badDocument("unreadable file")
        }
        guard data.count > 8, Array(data.prefix(4)) == magic else {
            throw FileIOError.badDocument("wrong magic")
        }
        var offset = 4
        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        guard Int(version) == formatVersion else {
            throw FileIOError.badDocument("unsupported version \(version)")
        }
        guard data.count >= offset + 4 else { throw FileIOError.badDocument("truncated header") }
        let metaLength = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        guard data.count >= offset + Int(metaLength) else { throw FileIOError.badDocument("truncated metadata") }
        let metaData = data.subdata(in: offset..<(offset + Int(metaLength)))
        offset += Int(metaLength)
        let decoder = JSONDecoder()
        let meta = try decoder.decode(DocumentMeta.self, from: metaData)

        var loadedLayers: [Layer] = []
        var warnings: [String] = []
        let doc = Document(width: meta.width, height: meta.height)
        for lm in meta.layers {
            guard data.count >= offset + lm.pngLength else {
                warnings.append("Layer \(lm.name) is truncated")
                break
            }
            let pngData = data.subdata(in: offset..<(offset + lm.pngLength))
            offset += lm.pngLength
            guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                warnings.append("Layer \(lm.name) could not be decoded")
                continue
            }
            let layer = Layer(name: lm.name, raster: Raster.from(cgImage: img))
            layer.isVisible = lm.isVisible
            layer.opacity = lm.opacity
            layer.isLocked = lm.isLocked
            layer.blendMode = BlendMode(rawValue: lm.blendMode) ?? .normal
            layer.adjustments = lm.adjustments.compactMap { am in
                guard let kind = AdjustmentKind(rawValue: am.kind) else { return nil }
                return Adjustment(kind: kind, amount: am.amount, amount2: am.amount2, enabled: am.enabled)
            }
            loadedLayers.append(layer)
        }
        if loadedLayers.isEmpty {
            let bg = Layer(name: "Background", width: meta.width, height: meta.height)
            bg.raster.fill(.white)
            loadedLayers = [bg]
            warnings.append("No usable layers; created a blank background")
        }
        doc.replaceLayersForLoad(loadedLayers, activeIndex: meta.activeLayerIndex)
        doc.fileURL = url
        doc.documentName = url.deletingPathExtension().lastPathComponent
        doc.dirty = false
        return (doc, warnings)
    }

    // MARK: Save (native)

    static func save(document: Document, to url: URL) throws {
        var layerPNGs: [Data] = []
        var layerMetas: [DocumentMeta.LayerMeta] = []
        for layer in document.layers {
            guard let img = layer.renderedImage() else { continue }
            guard let png = encodePNG(img) else {
                throw FileIOError.writeFailed("PNG encoding failed for layer \(layer.name)")
            }
            layerPNGs.append(png)
            layerMetas.append(DocumentMeta.LayerMeta(
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                blendMode: layer.blendMode.rawValue,
                isLocked: layer.isLocked,
                adjustments: layer.adjustments.map {
                    DocumentMeta.AdjustmentMeta(kind: $0.kind.rawValue, amount: $0.amount,
                                                amount2: $0.amount2, enabled: $0.enabled)
                },
                pngLength: png.count
            ))
        }
        let meta = DocumentMeta(version: formatVersion, width: document.width, height: document.height,
                                activeLayerIndex: document.activeLayerIndex, layers: layerMetas)
        let metaData = try JSONEncoder().encode(meta)

        var out = Data()
        out.append(contentsOf: magic)
        var v = UInt32(formatVersion).littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        var ml = UInt32(metaData.count).littleEndian
        withUnsafeBytes(of: &ml) { out.append(contentsOf: $0) }
        out.append(metaData)
        for png in layerPNGs { out.append(png) }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw FileIOError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Export (flat image)

    static func exportImage(document: Document, to url: URL) throws {
        guard let composite = document.flatten().makeImage() else {
            throw FileIOError.notAnImage
        }
        let ext = url.pathExtension.lowercased()
        if ext == "bmp" {
            try BMPCodec.encode(raster: document.flatten(), to: url)
            return
        }
        let type: UTType
        switch ext {
        case "jpg", "jpeg": type = .jpeg
        case "tif", "tiff": type = .tiff
        case "gif": type = .gif
        default: type = .png
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileIOError.writeFailed("unsupported destination")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(dest, composite, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FileIOError.writeFailed("could not finalize \(ext.uppercased())")
        }
    }

    // MARK: PNG helper

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - BMP codec (classic Paint files, 24-bit, bottom-up, 4-byte rows)

enum BMPCodec {
    /// Decodes a 24-bit or 32-bit uncompressed BMP into a Raster.
    static func decode(url: URL) throws -> Raster {
        let data = try Data(contentsOf: url)
        guard data.count >= 54, data[0] == 0x42, data[1] == 0x4D else {
            throw FileIOError.notAnImage
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }
        let pixelOffset = u32(10)
        let width = u32(18)
        let storedHeight = Int32(bitPattern: UInt32(u32(22)))
        let bpp = u16(28)
        let compression = u32(30)
        guard bpp == 24 || bpp == 32 else {
            throw FileIOError.badDocument("only 24/32-bit BMP is supported (got \(bpp)bpp)")
        }
        guard compression == 0 else {
            throw FileIOError.badDocument("compressed BMP is not supported")
        }
        let height = Int(abs(storedHeight))
        let bottomUp = storedHeight > 0
        let rowBytes = ((width * bpp + 31) / 32) * 4
        guard data.count >= pixelOffset + rowBytes * height else {
            throw FileIOError.badDocument("truncated pixel data")
        }
        let raster = Raster(width: width, height: height)
        for y in 0..<height {
            let srcRow = bottomUp ? (height - 1 - y) : y
            let base = pixelOffset + srcRow * rowBytes
            for x in 0..<width {
                let i = base + x * (bpp / 8)
                let b = data[i], g = data[i + 1], r = data[i + 2]
                let a: UInt8 = bpp == 32 ? data[i + 3] : 255
                raster.setPixel(x, y, PixelColor(r: r, g: g, b: b, a: a == 0 ? 255 : a))
            }
        }
        return raster
    }

    /// Encodes a raster as a standard 24-bit bottom-up BMP.
    static func encode(raster: Raster, to url: URL) throws {
        let width = raster.width, height = raster.height
        let rowBytes = ((width * 3 + 3) / 4) * 4
        let pixelDataSize = rowBytes * height
        let fileSize = 54 + pixelDataSize
        guard fileSize < 4_000_000_000 else { throw FileIOError.bitmapTooLarge }
        var out = Data(capacity: fileSize)
        func appendU16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func appendU32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(0x42); out.append(0x4D)          // "BM"
        appendU32(fileSize)
        appendU16(0); appendU16(0)
        appendU32(54)
        appendU32(40)
        appendU32(width)
        appendU32(height)
        appendU16(1)
        appendU16(24)
        appendU32(0)
        appendU32(pixelDataSize)
        appendU32(2835); appendU32(2835)
        appendU32(0); appendU32(0)
        let padding = rowBytes - width * 3
        for row in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                let c = raster.getPixel(x, row)
                out.append(c.b); out.append(c.g); out.append(c.r)
            }
            for _ in 0..<padding { out.append(0) }
        }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw FileIOError.writeFailed(error.localizedDescription)
        }
    }
}

extension Document {
    /// Convenience for callers that need a CGSize.
    var canvasSizeValue: CGSize { canvasSize }
}
