import CoreGraphics

struct DisplayUniforms {
    var scale: SIMD2<Float>
    var translation: SIMD2<Float>
}

struct CanvasViewport {
    let canvasSize: CGSize
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 32

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

    func fittedScale(viewSize: CGSize) -> CGFloat {
        let frame = visibleCanvasFrame(viewSize: viewSize)
        return min(frame.width / max(canvasSize.width, 1), frame.height / max(canvasSize.height, 1))
    }

    func canvasPoint(from viewPoint: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        let viewCenter = CGPoint(
            x: max(viewSize.width, 1) / 2 + pan.width,
            y: max(viewSize.height, 1) / 2 + pan.height
        )
        let scale = fittedScale(viewSize: viewSize) * zoom
        let canvasX = canvasSize.width / 2 + (viewPoint.x - viewCenter.x) / max(scale, 0.0001)
        let canvasY = canvasSize.height / 2 + (viewPoint.y - viewCenter.y) / max(scale, 0.0001)

        return SIMD2<Float>(Float(canvasX), Float(canvasY))
    }

    func viewPoint(from canvasPoint: SIMD2<Float>, viewSize: CGSize) -> CGPoint {
        let viewCenter = CGPoint(
            x: max(viewSize.width, 1) / 2 + pan.width,
            y: max(viewSize.height, 1) / 2 + pan.height
        )
        let scale = fittedScale(viewSize: viewSize) * zoom
        let local = CGPoint(
            x: (CGFloat(canvasPoint.x) - canvasSize.width / 2) * scale,
            y: (CGFloat(canvasPoint.y) - canvasSize.height / 2) * scale
        )

        return CGPoint(x: viewCenter.x + local.x, y: viewCenter.y + local.y)
    }

    func clampedCanvasPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            min(max(point.x, 0), Float(canvasSize.width)),
            min(max(point.y, 0), Float(canvasSize.height))
        )
    }

    func containsCanvasPoint(_ viewPoint: CGPoint, viewSize: CGSize) -> Bool {
        let point = canvasPoint(from: viewPoint, viewSize: viewSize)
        return point.x >= 0 &&
            point.y >= 0 &&
            point.x < Float(canvasSize.width) &&
            point.y < Float(canvasSize.height)
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

    func displayUniforms(viewSize: CGSize) -> DisplayUniforms {
        let scale = displayScale(viewSize: viewSize)
        return DisplayUniforms(
            scale: SIMD2<Float>(scale.x * Float(zoom), scale.y * Float(zoom)),
            translation: SIMD2<Float>(
                Float((pan.width / max(viewSize.width, 1)) * 2),
                Float((pan.height / max(viewSize.height, 1)) * 2)
            )
        )
    }

    mutating func panBy(_ delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
    }

    mutating func zoomBy(_ factor: CGFloat, around anchor: CGPoint, viewSize: CGSize) {
        let canvasAnchor = canvasPoint(from: anchor, viewSize: viewSize)
        zoom = min(max(zoom * factor, minZoom), maxZoom)
        let newAnchor = viewPoint(from: canvasAnchor, viewSize: viewSize)
        pan.width += anchor.x - newAnchor.x
        pan.height += anchor.y - newAnchor.y
    }

    mutating func fitToView() {
        zoom = 1
        pan = .zero
    }
}
