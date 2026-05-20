import XCTest
@testable import MetalBrushEngine

final class DiagnosticPerformanceTests: XCTestCase {
    func testLongStrokeDabGenerationPerformance() {
        measure {
            let engine = BrushEngine(state: makeState(spacing: 0.1, smoothing: 0.25), maxDabs: 10000)
            _ = engine.startStroke(with: point(x: 0, y: 0))
            for index in 1...500 {
                _ = engine.continueStroke(with: point(x: Float(index * 8), y: Float(index % 40)))
            }
            _ = engine.endStroke()
        }
    }

    func testHighDensityStrokeGenerationPerformanceNearDabCap() {
        measure {
            let engine = BrushEngine(state: makeState(spacing: 0.02, smoothing: 0), maxDabs: 10000)
            _ = engine.startStroke(with: point(x: 0, y: 0, size: 40))
            _ = engine.continueStroke(with: point(x: 12000, y: 0, size: 40))
            _ = engine.endStroke()
        }
    }

    func testViewportConversionPerformance() {
        let viewport = CanvasViewport(canvasSize: CGSize(width: 6000, height: 4000))
        let viewSize = CGSize(width: 1512, height: 982)
        var checksum = SIMD2<Float>(0, 0)

        measure {
            var localChecksum = SIMD2<Float>(0, 0)
            for index in 0..<20_000 {
                let point = CGPoint(x: CGFloat(index % 1512), y: CGFloat((index * 7) % 982))
                localChecksum += viewport.clampedCanvasPoint(viewport.canvasPoint(from: point, viewSize: viewSize))
            }
            checksum = localChecksum
        }
        XCTAssertGreaterThan(checksum.x + checksum.y, 0)
    }

    func testBrushSettingsDecodePerformance() {
        let json = Data("""
        {
          "spacing": 0.12,
          "flow": 0.8,
          "scatter": 0.2,
          "hardness": 0.4,
          "softness": 0.1,
          "rotationJitter": 0.3,
          "tiltInfluence": 0.6,
          "smudgeStrength": 0.5,
          "isSmudge": true,
          "rotationMode": 2
        }
        """.utf8)
        XCTAssertNotNil(try? JSONDecoder().decode(BrushSettings.self, from: json))

        measure {
            let decoder = JSONDecoder()
            for _ in 0..<5_000 {
                _ = try! decoder.decode(BrushSettings.self, from: json)
            }
        }
    }

    private func makeState(spacing: Float, smoothing: Float) -> BrushEngineState {
        var settings = BrushSettings()
        settings.spacing = spacing
        settings.scatter = 0
        settings.rotationJitter = 0
        settings.tiltInfluence = 0
        return BrushEngineState(
            settings: settings,
            brushColor: SIMD3<Float>(0.1, 0.2, 0.3),
            smoothing: smoothing,
            canvasSize: SIMD2<Float>(12000, 8000)
        )
    }

    private func point(x: Float, y: Float, size: Float = 20) -> BrushPoint {
        BrushPoint(
            position: SIMD2<Float>(x, y),
            pressure: 1,
            size: size,
            tiltX: 0,
            tiltY: 0,
            azimuth: 0,
            timestamp: 0,
            rotation: 0
        )
    }
}
