import Foundation

struct BrushEngineState {
    var settings = BrushSettings()
    var brushColor = SIMD3<Float>(0.365, 0.251, 0.216)
    var smoothing: Float = 0.3
    var canvasSize = SIMD2<Float>(6000, 4000)
}

final class BrushEngine {
    private var state: BrushEngineState
    private var lastPlacedPoint: BrushPoint?
    private var lastSmoothedPoint: BrushPoint?
    private var hasPlacedDabs = false
    private var lastStrokeRotation: Float = 0
    private let maxDabs: Int

    var isStrokeActive: Bool {
        lastPlacedPoint != nil
    }

    init(state: BrushEngineState = BrushEngineState(), maxDabs: Int = 10000) {
        self.state = state
        self.maxDabs = maxDabs
    }

    func updateState(_ state: BrushEngineState) {
        self.state = state
    }

    func updateSettings(_ settings: BrushSettings) {
        state.settings = settings
    }

    func startStroke(with point: BrushPoint) -> [DabInstance] {
        lastSmoothedPoint = point
        lastPlacedPoint = point
        hasPlacedDabs = false
        lastStrokeRotation = point.rotation
        return addDab(at: point, currentCount: 0).map { [$0] } ?? []
    }

    func continueStroke(with point: BrushPoint) -> [DabInstance] {
        guard let lastSmoothed = lastSmoothedPoint else { return [] }
        guard let lastPlaced = lastPlacedPoint else { return [] }

        let stabilization = min(max(state.smoothing, 0), 0.95)
        let inputWeight = 1.0 - stabilization
        let smoothedPosition = SIMD2<Float>(
            lastSmoothed.position.x * stabilization + point.position.x * inputWeight,
            lastSmoothed.position.y * stabilization + point.position.y * inputWeight
        )

        let dx = smoothedPosition.x - lastSmoothed.position.x
        let dy = smoothedPosition.y - lastSmoothed.position.y
        let movementDistance = hypot(dx, dy)
        let rotation = movementDistance > 0.001 ? atan2(dy, dx) : lastStrokeRotation
        lastStrokeRotation = rotation

        let smoothedPoint = BrushPoint(
            position: smoothedPosition,
            pressure: lastSmoothed.pressure * stabilization + point.pressure * inputWeight,
            size: lastSmoothed.size * stabilization + point.size * inputWeight,
            tiltX: lastSmoothed.tiltX * stabilization + point.tiltX * inputWeight,
            tiltY: lastSmoothed.tiltY * stabilization + point.tiltY * inputWeight,
            azimuth: lastSmoothed.azimuth * stabilization + point.azimuth * inputWeight,
            timestamp: point.timestamp,
            rotation: rotation
        )

        let dabs = interpolateDabs(from: lastPlaced, to: smoothedPoint)
        lastSmoothedPoint = smoothedPoint
        return dabs
    }

    func endStroke() -> [DabInstance] {
        var dabs: [DabInstance] = []
        if !hasPlacedDabs, let last = lastPlacedPoint, let dab = addDab(at: last, currentCount: 0) {
            dabs.append(dab)
        }

        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0
        return dabs
    }

    func resetStroke() {
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0
    }

    private func interpolateDabs(from start: BrushPoint, to end: BrushPoint) -> [DabInstance] {
        var dabs: [DabInstance] = []
        var current = start
        var remaining = distance(from: current.position, to: end.position)

        while remaining > 0.1 && dabs.count < maxDabs {
            let avgSize = (current.size + end.size) / 2.0
            let stepSize = max(1.0, avgSize * state.settings.spacing)
            guard remaining >= stepSize else { break }

            let t = stepSize / remaining
            let rotation = atan2(end.position.y - current.position.y, end.position.x - current.position.x)
            let point = interpolatedPoint(from: current, to: end, t: t, rotation: rotation)
            if let dab = addDab(at: point, currentCount: dabs.count) {
                dabs.append(dab)
            }

            current = point
            remaining = distance(from: current.position, to: end.position)
        }

        return dabs
    }

    private func addDab(at point: BrushPoint, currentCount: Int) -> DabInstance? {
        guard currentCount < maxDabs else { return nil }

        var position = point.position
        if state.settings.scatter > 0 {
            let jitterX = Float.random(in: -1...1) * state.settings.scatter * point.size * 0.5
            let jitterY = Float.random(in: -1...1) * state.settings.scatter * point.size * 0.5
            position.x += jitterX
            position.y += jitterY
        }

        position.x = min(max(position.x, 0), state.canvasSize.x)
        position.y = min(max(position.y, 0), state.canvasSize.y)

        var rotation: Float
        switch state.settings.rotationMode {
        case .fixed:
            rotation = 0
        case .random:
            rotation = Float.random(in: 0...(2 * Float.pi))
        case .followStroke:
            rotation = point.rotation
        }

        if state.settings.rotationJitter > 0 {
            rotation += Float.random(in: -1...1) * state.settings.rotationJitter * Float.pi
        }

        var tiltScale = SIMD2<Float>(1.0, 1.0)
        if state.settings.tiltInfluence > 0 {
            let tiltAmount = sqrt(point.tiltX * point.tiltX + point.tiltY * point.tiltY)
            if tiltAmount > 0.01 {
                let squash = max(0.2, 1.0 - tiltAmount * state.settings.tiltInfluence)
                let stretch = 1.0 + tiltAmount * state.settings.tiltInfluence * 0.5
                let tiltAngle = atan2(point.tiltY, point.tiltX)
                rotation = tiltAngle + .pi / 2
                tiltScale = SIMD2<Float>(stretch, squash)
            }
        }

        let smudge = state.settings.isSmudge ? state.settings.smudgeStrength : 0.0
        let dab = DabInstance(
            center: position,
            size: point.size,
            rotation: rotation,
            pressure: point.pressure,
            hardness: state.settings.hardness,
            softness: state.settings.softness,
            smudgeStrength: smudge,
            color: SIMD4<Float>(state.brushColor, 1.0),
            tiltScale: tiltScale,
            flow: state.settings.flow
        )

        lastPlacedPoint = point
        hasPlacedDabs = true
        return dab
    }

    private func distance(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Float {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func interpolatedPoint(from start: BrushPoint, to end: BrushPoint, t: Float, rotation: Float) -> BrushPoint {
        BrushPoint(
            position: SIMD2<Float>(
                start.position.x + (end.position.x - start.position.x) * t,
                start.position.y + (end.position.y - start.position.y) * t
            ),
            pressure: start.pressure + (end.pressure - start.pressure) * t,
            size: start.size + (end.size - start.size) * t,
            tiltX: start.tiltX + (end.tiltX - start.tiltX) * t,
            tiltY: start.tiltY + (end.tiltY - start.tiltY) * t,
            azimuth: start.azimuth + (end.azimuth - start.azimuth) * t,
            timestamp: start.timestamp + (end.timestamp - start.timestamp) * t,
            rotation: rotation
        )
    }
}
