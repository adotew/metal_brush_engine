import AppKit
import Foundation

struct CanvasDocumentManifest: Codable, Equatable {
    var canvasWidth: Int
    var canvasHeight: Int
    var selectedLayerIndex: Int
    var layers: [CanvasDocumentLayer]
}

struct CanvasDocumentLayer: Codable, Equatable {
    var name: String
    var isVisible: Bool
    var opacity: Float
    var filename: String
}

enum CanvasDocumentError: LocalizedError {
    case invalidDocument
    case unsupportedCanvasSize
    case missingLayer(String)
    case pngEncodingFailed
    case pngDecodingFailed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The document package is missing required data."
        case .unsupportedCanvasSize:
            return "The document canvas size does not match this app version."
        case .missingLayer(let filename):
            return "The document is missing layer image \(filename)."
        case .pngEncodingFailed:
            return "The canvas image could not be encoded as PNG."
        case .pngDecodingFailed(let url):
            return "The PNG image could not be decoded: \(url.lastPathComponent)."
        }
    }
}

final class CanvasDocumentStore {
    private let fileManager: FileManager
    private let manifestFilename = "manifest.json"
    private let layersDirectoryName = "layers"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func saveDocument(
        manifest: CanvasDocumentManifest,
        layerImages: [(filename: String, data: Data)],
        to url: URL
    ) throws {
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("MetalBrushDocument-\(UUID().uuidString)", isDirectory: true)
        let layersURL = temporaryURL.appendingPathComponent(layersDirectoryName, isDirectory: true)

        try fileManager.createDirectory(at: layersURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: temporaryURL.appendingPathComponent(manifestFilename))

        for image in layerImages {
            try image.data.write(to: layersURL.appendingPathComponent(image.filename))
        }

        let parentURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: url)
    }

    func loadDocument(from url: URL) throws -> (manifest: CanvasDocumentManifest, layerImages: [(CanvasDocumentLayer, NSBitmapImageRep)]) {
        let manifestURL = url.appendingPathComponent(manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CanvasDocumentError.invalidDocument
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CanvasDocumentManifest.self, from: manifestData)
        let layersURL = url.appendingPathComponent(layersDirectoryName, isDirectory: true)

        let images = try manifest.layers.map { layer -> (CanvasDocumentLayer, NSBitmapImageRep) in
            let imageURL = layersURL.appendingPathComponent(layer.filename)
            guard fileManager.fileExists(atPath: imageURL.path) else {
                throw CanvasDocumentError.missingLayer(layer.filename)
            }
            let data = try Data(contentsOf: imageURL)
            guard let bitmap = NSBitmapImageRep(data: data) else {
                throw CanvasDocumentError.pngDecodingFailed(imageURL)
            }
            return (layer, bitmap)
        }

        return (manifest, images)
    }

    func pngData(fromBGRA pixels: [UInt8], width: Int, height: Int) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: pixels.count)
        for index in 0..<(width * height) {
            let source = index * 4
            rgba[source + 0] = pixels[source + 2]
            rgba[source + 1] = pixels[source + 1]
            rgba[source + 2] = pixels[source + 0]
            rgba[source + 3] = pixels[source + 3]
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            throw CanvasDocumentError.pngEncodingFailed
        }

        guard let destination = bitmap.bitmapData else {
            throw CanvasDocumentError.pngEncodingFailed
        }
        rgba.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                memcpy(destination, baseAddress, rgba.count)
            }
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CanvasDocumentError.pngEncodingFailed
        }
        return data
    }

    func bgraPixels(from bitmap: NSBitmapImageRep, expectedWidth: Int, expectedHeight: Int) throws -> [UInt8] {
        guard bitmap.pixelsWide == expectedWidth, bitmap.pixelsHigh == expectedHeight else {
            throw CanvasDocumentError.unsupportedCanvasSize
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CanvasDocumentError.pngDecodingFailed(URL(fileURLWithPath: "layer.png"))
        }

        guard let cgImage = bitmap.cgImage else {
            throw CanvasDocumentError.pngDecodingFailed(URL(fileURLWithPath: "layer.png"))
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
