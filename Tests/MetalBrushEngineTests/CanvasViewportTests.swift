import XCTest
@testable import MetalBrushEngine

final class CanvasViewportTests: XCTestCase {
    private let viewport = CanvasViewport(canvasSize: CGSize(width: 6000, height: 4000))

    func testVisibleCanvasFrameInWideViewAddsHorizontalBars() {
        let frame = viewport.visibleCanvasFrame(viewSize: CGSize(width: 1200, height: 600))

        XCTAssertEqual(frame.minX, 150, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, 900, accuracy: 0.001)
        XCTAssertEqual(frame.height, 600, accuracy: 0.001)
    }

    func testVisibleCanvasFrameInTallViewAddsVerticalBars() {
        let frame = viewport.visibleCanvasFrame(viewSize: CGSize(width: 600, height: 800))

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 200, accuracy: 0.001)
        XCTAssertEqual(frame.width, 600, accuracy: 0.001)
        XCTAssertEqual(frame.height, 400, accuracy: 0.001)
    }

    func testCanvasPointConvertsVisibleFrameCenterToCanvasCenter() {
        let point = viewport.canvasPoint(
            from: CGPoint(x: 600, y: 300),
            viewSize: CGSize(width: 1200, height: 600)
        )

        XCTAssertEqual(point.x, 3000, accuracy: 0.001)
        XCTAssertEqual(point.y, 2000, accuracy: 0.001)
    }

    func testClampedCanvasPointConstrainsToCanvasBounds() {
        let point = viewport.clampedCanvasPoint(SIMD2<Float>(-40, 5000))

        XCTAssertEqual(point.x, 0, accuracy: 0.001)
        XCTAssertEqual(point.y, 4000, accuracy: 0.001)
    }

    func testContainsCanvasPointRejectsLetterboxBars() {
        let viewSize = CGSize(width: 1200, height: 600)

        XCTAssertFalse(viewport.containsCanvasPoint(CGPoint(x: 149, y: 300), viewSize: viewSize))
        XCTAssertTrue(viewport.containsCanvasPoint(CGPoint(x: 150, y: 300), viewSize: viewSize))
        XCTAssertTrue(viewport.containsCanvasPoint(CGPoint(x: 1049, y: 300), viewSize: viewSize))
        XCTAssertFalse(viewport.containsCanvasPoint(CGPoint(x: 1050, y: 300), viewSize: viewSize))
    }
}
