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

    func testZoomAroundPointerKeepsCanvasPointUnderPointer() {
        var viewport = CanvasViewport(canvasSize: CGSize(width: 6000, height: 4000))
        let viewSize = CGSize(width: 1200, height: 600)
        let anchor = CGPoint(x: 300, y: 200)
        let before = viewport.canvasPoint(from: anchor, viewSize: viewSize)

        viewport.zoomBy(2, around: anchor, viewSize: viewSize)
        let after = viewport.canvasPoint(from: anchor, viewSize: viewSize)

        XCTAssertEqual(viewport.zoom, 2, accuracy: 0.001)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    func testPanMovesCanvasPointOppositeViewDelta() {
        var viewport = CanvasViewport(canvasSize: CGSize(width: 6000, height: 4000))
        let viewSize = CGSize(width: 1200, height: 600)

        viewport.panBy(CGSize(width: 90, height: 60))
        let point = viewport.canvasPoint(from: CGPoint(x: 600, y: 300), viewSize: viewSize)

        XCTAssertEqual(point.x, 2400, accuracy: 0.001)
        XCTAssertEqual(point.y, 1600, accuracy: 0.001)
    }

    func testFitToViewResetsInteractiveTransform() {
        var viewport = CanvasViewport(canvasSize: CGSize(width: 6000, height: 4000))
        viewport.panBy(CGSize(width: 120, height: -80))
        viewport.zoomBy(3, around: CGPoint(x: 600, y: 300), viewSize: CGSize(width: 1200, height: 600))

        viewport.fitToView()

        XCTAssertEqual(viewport.zoom, 1, accuracy: 0.001)
        XCTAssertEqual(viewport.pan.width, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.pan.height, 0, accuracy: 0.001)
    }
}
