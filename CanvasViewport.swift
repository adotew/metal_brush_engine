import CoreGraphics

struct CanvasViewport {
    let canvasSize: CGSize

    func visibleCanvasFrame(viewSize: CGSize) -> CGRect {
        let viewW = max(viewSize.width, 1)
        let viewH = max(viewSize.height, 1)
        let canvasAspect = canvasSize.width / canvasSize.height
        let viewAspect = viewW / viewH

        if viewAspect > canvasAspect {
            let visibleCanvasW = viewH * canvasAspect
            let barW = (viewW - visibleCanvasW) / 2
            return CGRect(x: barW, y: 0, width: visibleCanvasW, height: viewH)
        } else {
            let visibleCanvasH = viewW / canvasAspect
            let barH = (viewH - visibleCanvasH) / 2
            return CGRect(x: 0, y: barH, width: viewW, height: visibleCanvasH)
        }
    }

    func canvasPoint(from viewPoint: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        let visibleCanvas = visibleCanvasFrame(viewSize: viewSize)
        let relX = (viewPoint.x - visibleCanvas.minX) / max(visibleCanvas.width, 1)
        let relY = (viewPoint.y - visibleCanvas.minY) / max(visibleCanvas.height, 1)
        let canvasX = Float(relX) * Float(canvasSize.width)
        let canvasY = Float(relY) * Float(canvasSize.height)

        return SIMD2<Float>(canvasX, canvasY)
    }

    func clampedCanvasPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            min(max(point.x, 0), Float(canvasSize.width)),
            min(max(point.y, 0), Float(canvasSize.height))
        )
    }

    func containsCanvasPoint(_ viewPoint: CGPoint, viewSize: CGSize) -> Bool {
        visibleCanvasFrame(viewSize: viewSize).contains(viewPoint)
    }

    func displayScale(viewSize: CGSize) -> SIMD2<Float> {
        let viewW = Float(max(viewSize.width, 1))
        let viewH = Float(max(viewSize.height, 1))
        let canvasAspect = Float(canvasSize.width / canvasSize.height)
        let viewAspect = viewW / viewH

        if viewAspect > canvasAspect {
            return SIMD2<Float>(canvasAspect / viewAspect, 1.0)
        } else {
            return SIMD2<Float>(1.0, viewAspect / canvasAspect)
        }
    }
}
