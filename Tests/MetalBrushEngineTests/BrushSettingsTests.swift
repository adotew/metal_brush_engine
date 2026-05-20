import XCTest
@testable import MetalBrushEngine

final class BrushSettingsTests: XCTestCase {
    func testDecodingMissingSidecarFieldsFallsBackToDefaults() throws {
        let json = """
        {
          "spacing": 0.25,
          "flow": 0.5,
          "rotationMode": 1
        }
        """

        let settings = try JSONDecoder().decode(BrushSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.spacing, 0.25, accuracy: 0.001)
        XCTAssertEqual(settings.flow, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.rotationMode, .fixed)
        XCTAssertEqual(settings.scatter, 0, accuracy: 0.001)
        XCTAssertEqual(settings.hardness, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.softness, 0, accuracy: 0.001)
        XCTAssertEqual(settings.rotationJitter, 0, accuracy: 0.001)
        XCTAssertEqual(settings.tiltInfluence, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.smudgeStrength, 0.7, accuracy: 0.001)
        XCTAssertFalse(settings.isSmudge)
    }

    func testEncodingPreservesExistingSidecarShape() throws {
        let settings = BrushSettings(
            spacing: 0.2,
            flow: 0.8,
            scatter: 0.1,
            hardness: 0.4,
            softness: 0.3,
            rotationJitter: 0.2,
            tiltInfluence: 0.6,
            smudgeStrength: 0.9,
            isSmudge: true,
            rotationMode: .random
        )

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["spacing"] as? Double ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(object["flow"] as? Double ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(object["scatter"] as? Double ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(object["rotationMode"] as? Int, RotationMode.random.rawValue)
        XCTAssertEqual(object["isSmudge"] as? Bool, true)
    }
}
