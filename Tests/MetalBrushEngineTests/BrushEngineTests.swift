import XCTest
@testable import MetalBrushEngine

final class BrushEngineTests: XCTestCase {
    func testStartStrokeCreatesInitialDab() {
        let engine = BrushEngine(state: makeState())
        let dabs = engine.startStroke(with: point(x: 20, y: 30, size: 12, pressure: 0.75))

        XCTAssertEqual(dabs.count, 1)
        XCTAssertEqual(dabs[0].center.x, 20, accuracy: 0.001)
        XCTAssertEqual(dabs[0].center.y, 30, accuracy: 0.001)
        XCTAssertEqual(dabs[0].size, 12, accuracy: 0.001)
        XCTAssertEqual(dabs[0].pressure, 0.75, accuracy: 0.001)
    }

    func testSpacingProducesStableDabCountsForEquivalentSlowAndFastStrokes() {
        let slowEngine = BrushEngine(state: makeState(spacing: 0.5, smoothing: 0))
        var slowDabs = slowEngine.startStroke(with: point(x: 0, y: 0, size: 10))
        for x in stride(from: 10, through: 100, by: 10) {
            slowDabs.append(contentsOf: slowEngine.continueStroke(with: point(x: Float(x), y: 0, size: 10)))
        }

        let fastEngine = BrushEngine(state: makeState(spacing: 0.5, smoothing: 0))
        var fastDabs = fastEngine.startStroke(with: point(x: 0, y: 0, size: 10))
        fastDabs.append(contentsOf: fastEngine.continueStroke(with: point(x: 100, y: 0, size: 10)))

        XCTAssertEqual(slowDabs.count, 21)
        XCTAssertEqual(fastDabs.count, slowDabs.count)
        XCTAssertEqual(fastDabs.last?.center.x ?? -1, 100, accuracy: 0.001)
    }

    func testSmoothingZeroFollowsRawInputMoreCloselyThanHighSmoothing() {
        let rawEngine = BrushEngine(state: makeState(spacing: 1.0, smoothing: 0))
        _ = rawEngine.startStroke(with: point(x: 0, y: 0, size: 10))
        let rawDabs = rawEngine.continueStroke(with: point(x: 100, y: 0, size: 10))

        let smoothedEngine = BrushEngine(state: makeState(spacing: 1.0, smoothing: 0.8))
        _ = smoothedEngine.startStroke(with: point(x: 0, y: 0, size: 10))
        let smoothedDabs = smoothedEngine.continueStroke(with: point(x: 100, y: 0, size: 10))

        XCTAssertEqual(rawDabs.last?.center.x ?? -1, 100, accuracy: 0.001)
        XCTAssertLessThan(smoothedDabs.last?.center.x ?? 100, rawDabs.last?.center.x ?? 0)
        XCTAssertLessThan(smoothedDabs.count, rawDabs.count)
    }

    func testRotationModesUseFixedOrFollowStrokeRotation() {
        let fixedEngine = BrushEngine(state: makeState(rotationMode: .fixed, smoothing: 0))
        _ = fixedEngine.startStroke(with: point(x: 0, y: 0, rotation: 1.2))
        let fixedDabs = fixedEngine.continueStroke(with: point(x: 20, y: 0, rotation: 1.2))

        let followEngine = BrushEngine(state: makeState(rotationMode: .followStroke, smoothing: 0))
        _ = followEngine.startStroke(with: point(x: 0, y: 0))
        let followDabs = followEngine.continueStroke(with: point(x: 20, y: 20))

        XCTAssertEqual(fixedDabs.last?.rotation ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(followDabs.last?.rotation ?? 0, Float.pi / 4, accuracy: 0.001)
    }

    func testEngineCapsGeneratedDabsPerContinuation() {
        let engine = BrushEngine(state: makeState(spacing: 0.02, smoothing: 0), maxDabs: 12)
        _ = engine.startStroke(with: point(x: 0, y: 0, size: 20))

        let dabs = engine.continueStroke(with: point(x: 1000, y: 0, size: 20))

        XCTAssertEqual(dabs.count, 12)
    }

    func testEraserSettingsMarkGeneratedDabs() {
        var state = makeState()
        state.settings.isEraser = true
        let engine = BrushEngine(state: state)

        let dabs = engine.startStroke(with: point(x: 20, y: 30, size: 12))

        XCTAssertEqual(dabs.first?.isEraser ?? 0, 1, accuracy: 0.001)
    }

    private func makeState(
        spacing: Float = 0.5,
        rotationMode: RotationMode = .followStroke,
        smoothing: Float = 0
    ) -> BrushEngineState {
        var settings = BrushSettings()
        settings.spacing = spacing
        settings.rotationMode = rotationMode
        settings.scatter = 0
        settings.rotationJitter = 0
        settings.tiltInfluence = 0
        return BrushEngineState(
            settings: settings,
            brushColor: SIMD3<Float>(0.1, 0.2, 0.3),
            smoothing: smoothing,
            canvasSize: SIMD2<Float>(2000, 1000)
        )
    }

    private func point(
        x: Float,
        y: Float,
        size: Float = 10,
        pressure: Float = 1,
        rotation: Float = 0
    ) -> BrushPoint {
        BrushPoint(
            position: SIMD2<Float>(x, y),
            pressure: pressure,
            size: size,
            tiltX: 0,
            tiltY: 0,
            azimuth: 0,
            timestamp: 0,
            rotation: rotation
        )
    }
}
