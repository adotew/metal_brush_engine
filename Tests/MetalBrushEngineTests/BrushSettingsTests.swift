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
        XCTAssertEqual(settings.sizePressureCurve, 0.75, accuracy: 0.001)
        XCTAssertEqual(settings.opacityPressureCurve, 1.25, accuracy: 0.001)
        XCTAssertEqual(settings.minimumOpacity, 0.08, accuracy: 0.001)
        XCTAssertEqual(settings.velocitySizeInfluence, 0.12, accuracy: 0.001)
        XCTAssertEqual(settings.velocityOpacityInfluence, 0.08, accuracy: 0.001)
        XCTAssertEqual(settings.startTaperLength, 10, accuracy: 0.001)
        XCTAssertEqual(settings.endTaperLength, 18, accuracy: 0.001)
        XCTAssertEqual(settings.streamline, 0.3, accuracy: 0.001)
        XCTAssertEqual(settings.rotationJitter, 0, accuracy: 0.001)
        XCTAssertEqual(settings.tiltInfluence, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.smudgeStrength, 0.7, accuracy: 0.001)
        XCTAssertFalse(settings.isSmudge)
        XCTAssertFalse(settings.isEraser)
    }

    func testEncodingPreservesExistingSidecarShape() throws {
        let settings = BrushSettings(
            spacing: 0.2,
            flow: 0.8,
            scatter: 0.1,
            hardness: 0.4,
            softness: 0.3,
            sizePressureCurve: 0.7,
            opacityPressureCurve: 1.4,
            minimumOpacity: 0.12,
            velocitySizeInfluence: 0.2,
            velocityOpacityInfluence: 0.3,
            startTaperLength: 11,
            endTaperLength: 17,
            streamline: 0.45,
            rotationJitter: 0.2,
            tiltInfluence: 0.6,
            smudgeStrength: 0.9,
            isSmudge: true,
            isEraser: true,
            rotationMode: .random
        )

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["spacing"] as? Double ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(object["flow"] as? Double ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(object["scatter"] as? Double ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(object["sizePressureCurve"] as? Double ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(object["opacityPressureCurve"] as? Double ?? -1, 1.4, accuracy: 0.001)
        XCTAssertEqual(object["minimumOpacity"] as? Double ?? -1, 0.12, accuracy: 0.001)
        XCTAssertEqual(object["velocitySizeInfluence"] as? Double ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(object["velocityOpacityInfluence"] as? Double ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(object["startTaperLength"] as? Double ?? -1, 11, accuracy: 0.001)
        XCTAssertEqual(object["endTaperLength"] as? Double ?? -1, 17, accuracy: 0.001)
        XCTAssertEqual(object["streamline"] as? Double ?? -1, 0.45, accuracy: 0.001)
        XCTAssertEqual(object["rotationMode"] as? Int, RotationMode.random.rawValue)
        XCTAssertEqual(object["isSmudge"] as? Bool, true)
        XCTAssertEqual(object["isEraser"] as? Bool, true)
    }
}
