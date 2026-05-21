import AppKit
import XCTest
@testable import MetalBrushEngine

final class CanvasDocumentStoreTests: XCTestCase {
    func testManifestRoundTripsThroughDocumentPackage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalBrushDocumentTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CanvasDocumentStore()
        let manifest = CanvasDocumentManifest(
            canvasWidth: 6000,
            canvasHeight: 4000,
            selectedLayerIndex: 1,
            layers: [
                CanvasDocumentLayer(name: "Background", isVisible: true, opacity: 1, filename: "layer-000.png"),
                CanvasDocumentLayer(name: "Ink", isVisible: false, opacity: 0.4, filename: "layer-001.png")
            ]
        )
        let pngData = try store.pngData(fromBGRA: solidPixels(width: 2, height: 2), width: 2, height: 2)

        try store.saveDocument(
            manifest: manifest,
            layerImages: [
                ("layer-000.png", pngData),
                ("layer-001.png", pngData)
            ],
            to: directory
        )

        let loaded = try store.loadDocument(from: directory)

        XCTAssertEqual(loaded.manifest, manifest)
        XCTAssertEqual(loaded.layerImages.count, 2)
        XCTAssertEqual(loaded.layerImages[0].1.pixelsWide, 2)
        XCTAssertEqual(loaded.layerImages[0].1.pixelsHigh, 2)
    }

    func testBGRAEncodingAndDecodingPreservesPixelChannels() throws {
        let store = CanvasDocumentStore()
        let pixels: [UInt8] = [
            10, 20, 30, 255,
            40, 50, 60, 128,
            70, 80, 90, 64,
            100, 110, 120, 0
        ]

        let pngData = try store.pngData(fromBGRA: pixels, width: 2, height: 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        let decoded = try store.bgraPixels(from: bitmap, expectedWidth: 2, expectedHeight: 2)

        XCTAssertEqual(decoded[0], 10)
        XCTAssertEqual(decoded[1], 20)
        XCTAssertEqual(decoded[2], 30)
        XCTAssertEqual(decoded[3], 255)
    }

    private func solidPixels(width: Int, height: Int) -> [UInt8] {
        Array(repeating: 255, count: width * height * 4)
    }
}
