import MetalKit
import SwiftUI

class BrushMTKView: MTKView {
    var brushRenderer: BrushRenderer?
    var isDrawing = false
    var lastPoint: CGPoint?
    var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.hide()
        brushRenderer?.showCursor = true
        setNeedsDisplay(bounds)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.unhide()
        brushRenderer?.showCursor = false
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        brushRenderer?.cursorPosition = SIMD2<Float>(Float(point.x), Float(point.y))
        setNeedsDisplay(bounds)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let isCommand = flags.contains(.command)
        guard isCommand, let chars = event.charactersIgnoringModifiers, chars == "z" else {
            super.keyDown(with: event)
            return
        }
        if flags.contains(.shift) {
            brushRenderer?.redo()
        } else {
            brushRenderer?.undo()
        }
        setNeedsDisplay(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard brushRenderer?.isPointOverCanvas(point, in: self) == true else { return }

        isDrawing = true
        lastPoint = point
        brushRenderer?.cursorPosition = SIMD2<Float>(Float(point.x), Float(point.y))

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.startStroke(with: brushPoint)
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        brushRenderer?.cursorPosition = SIMD2<Float>(Float(point.x), Float(point.y))

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.continueStroke(with: brushPoint)

        lastPoint = point
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if isDrawing {
            brushRenderer?.endStroke()
        }
        isDrawing = false
        lastPoint = nil
        setNeedsDisplay(bounds)
    }

    override func pressureChange(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        let normalizedPos = brushRenderer?.normalizePoint(location, in: self) ?? .zero
        let baseSize = brushRenderer?.maxBrushSize ?? 30.0
        let minSize = brushRenderer?.minBrushSize ?? 2.0
        let size = minSize + (baseSize - minSize) * clampedPressure

        return BrushPoint(
            position: normalizedPos,
            pressure: clampedPressure,
            size: size,
            tiltX: Float(tilt.x),
            tiltY: Float(tilt.y),
            azimuth: 0,
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
        mtkView.isPaused = true
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
        nsView.setNeedsDisplay(nsView.bounds)
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
