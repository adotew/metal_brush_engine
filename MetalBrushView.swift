import MetalKit
import SwiftUI

class BrushMTKView: MTKView {
    var brushRenderer: BrushRenderer?
    var isDrawing = false
    var lastPoint: CGPoint?
    var lastTimestamp: TimeInterval?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        isDrawing = true
        let point = convert(event.locationInWindow, from: nil)
        print("[EVENT] mouseDown at \(point), renderer=\(brushRenderer != nil)")
        lastPoint = point
        lastTimestamp = event.timestamp

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.startStroke(with: brushPoint)
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        print("[EVENT] mouseDragged at \(point)")

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.continueStroke(with: brushPoint)

        lastPoint = point
        lastTimestamp = event.timestamp
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        print("[EVENT] mouseUp")
        isDrawing = false
        lastPoint = nil
        lastTimestamp = nil
        brushRenderer?.endStroke()
    }

    override func pressureChange(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        print("[EVENT] pressureChange at \(point)")
        lastPoint = point

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.continueStroke(with: brushPoint)
        setNeedsDisplay(bounds)
    }

    private func createBrushPoint(from event: NSEvent, location: CGPoint) -> BrushPoint {
        let rawPressure = Float(event.pressure)
        let clampedPressure = max(rawPressure, 0.1)

        let tilt = event.tilt

        let timestamp = Float(event.timestamp)
        var velocity: Float = 0.0
        if let lastT = lastTimestamp, lastT > 0, let lastP = lastPoint {
            let dt = Float(event.timestamp - lastT)
            if dt > 0 {
                let dx = Float(location.x - lastP.x)
                let dy = Float(location.y - lastP.y)
                velocity = sqrt(dx * dx + dy * dy) / dt
            }
        }

        let normalizedPos = brushRenderer?.normalizePoint(location, in: self) ?? .zero
        let baseSize = brushRenderer?.maxBrushSize ?? 30.0
        let minSize = brushRenderer?.minBrushSize ?? 2.0
        let size = minSize + (baseSize - minSize) * clampedPressure

        print(String(format: "[INPUT] rawP=%.3f clampP=%.3f size=%.2f vel=%.2f pos=%.1f,%.1f",
                     rawPressure, clampedPressure, size, velocity,
                     normalizedPos.x, normalizedPos.y))

        return BrushPoint(
            position: normalizedPos,
            pressure: clampedPressure,
            size: size,
            tiltX: Float(tilt.x),
            tiltY: Float(tilt.y),
            azimuth: 0,
            velocity: velocity,
            timestamp: timestamp,
            rotation: 0
        )
    }
}

struct MetalBrushView: NSViewRepresentable {
    @ObservedObject var renderer: BrushRenderer

    func makeNSView(context: Context) -> MTKView {
        let mtkView = BrushMTKView()
        mtkView.device = renderer.device
        mtkView.delegate = context.coordinator
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = true
        mtkView.brushRenderer = renderer

        let coordinator = context.coordinator
        coordinator.renderer = renderer
        coordinator.mtkView = mtkView

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let brushView = nsView as? BrushMTKView {
            brushView.brushRenderer = renderer
        }
        context.coordinator.renderer = renderer
        context.coordinator.mtkView = nsView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var renderer: BrushRenderer?
        var mtkView: MTKView?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Canvas is fixed at 2000x2000; display scaling is handled in render
        }

        func draw(in view: MTKView) {
            renderer?.render(to: view)
        }
    }
}
