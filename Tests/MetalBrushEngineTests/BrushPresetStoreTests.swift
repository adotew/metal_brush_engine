import Metal
import XCTest
@testable import MetalBrushEngine

final class BrushPresetStoreTests: XCTestCase {
    func testLoadPresetsCreatesDefaultBrushWhenMissing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let directory = temporaryBrushDirectory()
        let store = BrushPresetStore(device: device, brushesDirectoryOverride: directory)

        let presets = store.loadPresets()

        XCTAssertTrue(presets.contains { $0.name == "Default" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Default.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Default.json").path))
    }

    func testLoadPresetsDoesNotOverwriteExistingDefaultSidecars() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let directory = temporaryBrushDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingSettings = BrushSettings(spacing: 0.31, flow: 0.44, isEraser: true)
        let existingData = try JSONEncoder().encode(existingSettings)
        try existingData.write(to: directory.appendingPathComponent("Default.json"))

        let store = BrushPresetStore(device: device, brushesDirectoryOverride: directory)
        let presets = store.loadPresets()
        let defaultPreset = try XCTUnwrap(presets.first { $0.name == "Default" })

        XCTAssertEqual(defaultPreset.settings.spacing, 0.31, accuracy: 0.001)
        XCTAssertEqual(defaultPreset.settings.flow, 0.44, accuracy: 0.001)
        XCTAssertTrue(defaultPreset.settings.isEraser)
    }

    func testLoadPresetsDoesNotCreateDefaultBrushWhenBrushFolderAlreadyHasBrushes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let directory = temporaryBrushDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Write an invalid PNG; the store should still not create Default
        try Data([0]).write(to: directory.appendingPathComponent("Custom.png"))

        let store = BrushPresetStore(device: device, brushesDirectoryOverride: directory)
        _ = store.loadPresets()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Default.png").path))
    }

    private func temporaryBrushDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalBrushEngineTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
