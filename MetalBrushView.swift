import MetalKit
import SwiftUI

class BrushMTKView: MTKView {
    var brushRenderer: BrushRenderer?
    enum InteractionMode {
        case idle
        case drawing
        case panning
    }

    var interactionMode: InteractionMode = .idle
    var lastPoint: CGPoint?
    var trackingArea: NSTrackingArea?
    var isSpaceDown = false

    private var isDrawing: Bool {
        interactionMode == .drawing
    }

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
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if chars == " " {
            isSpaceDown = true
            return
        }

        guard isCommand else {
            super.keyDown(with: event)
            return
        }

        switch chars {
        case "z" where flags.contains(.shift):
            brushRenderer?.redo()
        case "z":
            brushRenderer?.undo()
        case "0":
            brushRenderer?.fitViewportToView()
        default:
            super.keyDown(with: event)
            return
        }
        setNeedsDisplay(bounds)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            isSpaceDown = false
            if interactionMode == .panning {
                interactionMode = .idle
                lastPoint = nil
            }
            return
        }
        super.keyUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if isSpaceDown {
            interactionMode = .panning
            lastPoint = point
            brushRenderer?.showCursor = false
            return
        }

        guard brushRenderer?.isPointOverCanvas(point, in: self) == true else { return }

        interactionMode = .drawing
        lastPoint = point
        brushRenderer?.cursorPosition = SIMD2<Float>(Float(point.x), Float(point.y))

        let brushPoint = createBrushPoint(from: event, location: point)
        brushRenderer?.startStroke(with: brushPoint)
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .drawing:
            brushRenderer?.cursorPosition = SIMD2<Float>(Float(point.x), Float(point.y))
            let brushPoint = createBrushPoint(from: event, location: point)
            brushRenderer?.continueStroke(with: brushPoint)
        case .panning:
            if let lastPoint {
                brushRenderer?.panViewport(by: CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y))
            }
        case .idle:
            break
        }

        lastPoint = point
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if isDrawing {
            brushRenderer?.endStroke()
        }
        interactionMode = .idle
        lastPoint = nil
        brushRenderer?.showCursor = true
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

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor = CGFloat(pow(1.01, Double(event.scrollingDeltaY)))
            brushRenderer?.zoomViewport(by: factor, around: point, in: self)
        } else {
            brushRenderer?.panViewport(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        setNeedsDisplay(bounds)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        brushRenderer?.zoomViewport(by: 1 + event.magnification, around: point, in: self)
        setNeedsDisplay(bounds)
    }

    private func createBrushPoint(from event: NSEvent, location: CGPoint) -> BrushPoint {
        let rawPressure = Float(event.pressure)
        let clampedPressure = max(rawPressure, 0.1)

        let tilt = event.tilt

        let timestamp = Float(event.timestamp)
        let rawPosition = brushRenderer?.normalizePoint(location, in: self) ?? .zero
        let normalizedPos = brushRenderer?.clampedCanvasPoint(rawPosition) ?? rawPosition
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
