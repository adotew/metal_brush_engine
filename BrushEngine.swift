import Foundation

struct BrushEngineState {
    var settings = BrushSettings()
    var brushColor = SIMD3<Float>(0.365, 0.251, 0.216)
    var smoothing: Float = 0.3
    var canvasSize = SIMD2<Float>(6000, 4000)
    var minimumBrushSize: Float = 2.0
}

final class BrushEngine {
    private struct QueuedDab {
        var dab: DabInstance
        var distance: Float
    }

    private var state: BrushEngineState
    private var lastPlacedPoint: BrushPoint?
    private var lastSmoothedPoint: BrushPoint?
    private var hasPlacedDabs = false
    private var lastStrokeRotation: Float = 0
    private var strokeDistance: Float = 0
    private var queuedTailDabs: [QueuedDab] = []
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
        strokeDistance = 0
        queuedTailDabs.removeAll()
        return addDab(at: point, currentCount: 0, distanceAlongStroke: 0)
    }

    func continueStroke(with point: BrushPoint) -> [DabInstance] {
        guard let lastSmoothed = lastSmoothedPoint else { return [] }
        guard let lastPlaced = lastPlacedPoint else { return [] }

        let segmentDistance = distance(from: lastSmoothed.position, to: point.position)
        let deltaTime = max(point.timestamp - lastSmoothed.timestamp, 1.0 / 120.0)
        let velocity = segmentDistance / deltaTime
        let velocityAmount = min(max(velocity / 3200.0, 0), 1)
        let streamline = min(max(max(state.smoothing, state.settings.streamline), 0), 0.95)
        let stabilization = min(max(streamline * (0.68 - velocityAmount * 0.48), 0), 0.88)
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
            size: point.size,
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
        if !hasPlacedDabs, let last = lastPlacedPoint {
            dabs.append(contentsOf: addDab(at: last, currentCount: 0, distanceAlongStroke: strokeDistance))
        }

        dabs.append(contentsOf: flushQueuedTailDabs())
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0
        strokeDistance = 0
        queuedTailDabs.removeAll()
        return dabs
    }

    func resetStroke() {
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0
        strokeDistance = 0
        queuedTailDabs.removeAll()
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
            strokeDistance += distance(from: current.position, to: point.position)
            dabs.append(contentsOf: addDab(at: point, currentCount: dabs.count, distanceAlongStroke: strokeDistance))

            current = point
            remaining = distance(from: current.position, to: end.position)
        }

        return dabs
    }

    private func addDab(at point: BrushPoint, currentCount: Int, distanceAlongStroke: Float) -> [DabInstance] {
        guard currentCount < maxDabs else { return [] }

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

        let pressure = min(max(point.pressure, 0.0), 1.0)
        let sizeResponse = pow(max(pressure, 0.001), max(state.settings.sizePressureCurve, 0.05))
        let opacityResponse = pow(max(pressure, 0.001), max(state.settings.opacityPressureCurve, 0.05))
        let velocityAmount = velocityAmount(at: point)
        let velocitySizeMultiplier = 1.0 - min(max(state.settings.velocitySizeInfluence, 0), 0.9) * velocityAmount
        let velocityOpacityMultiplier = 1.0 - min(max(state.settings.velocityOpacityInfluence, 0), 0.9) * velocityAmount
        let taperMultiplier = startTaperMultiplier(distanceAlongStroke)
        let maxSize = max(point.size, state.minimumBrushSize)
        let size = max(
            state.minimumBrushSize,
            (state.minimumBrushSize + (maxSize - state.minimumBrushSize) * sizeResponse) * velocitySizeMultiplier
        )
        let opacity = min(
            max(state.settings.minimumOpacity + (1.0 - state.settings.minimumOpacity) * opacityResponse, 0),
            1
        ) * velocityOpacityMultiplier * taperMultiplier
        let smudge = state.settings.isSmudge ? state.settings.smudgeStrength : 0.0
        let dab = DabInstance(
            center: position,
            size: size,
            rotation: rotation,
            pressure: pressure,
            hardness: state.settings.hardness,
            softness: state.settings.softness,
            smudgeStrength: smudge,
            color: SIMD4<Float>(state.brushColor, 1.0),
            tiltScale: tiltScale,
            flow: state.settings.flow,
            opacity: opacity,
            isEraser: state.settings.isEraser ? 1.0 : 0.0
        )

        lastPlacedPoint = point
        hasPlacedDabs = true
        return queueOrEmit(dab, distance: distanceAlongStroke)
    }

    private func queueOrEmit(_ dab: DabInstance, distance: Float) -> [DabInstance] {
        let taperLength = max(state.settings.endTaperLength, 0)
        guard taperLength > 0 else { return [dab] }

        queuedTailDabs.append(QueuedDab(dab: dab, distance: distance))

        var emitted: [DabInstance] = []
        while let first = queuedTailDabs.first,
              let last = queuedTailDabs.last,
              last.distance - first.distance > taperLength {
            emitted.append(first.dab)
            queuedTailDabs.removeFirst()
        }
        return emitted
    }

    private func flushQueuedTailDabs() -> [DabInstance] {
        let taperLength = max(state.settings.endTaperLength, 0)
        defer { queuedTailDabs.removeAll() }

        guard taperLength > 0 else {
            return queuedTailDabs.map(\.dab)
        }

        if strokeDistance < 1.0, var tap = queuedTailDabs.first?.dab {
            tap.opacity *= 0.45
            tap.size = max(state.minimumBrushSize, tap.size * 0.7)
            return [tap]
        }

        return queuedTailDabs.map { queued in
            var dab = queued.dab
            let distanceToEnd = max(strokeDistance - queued.distance, 0)
            let multiplier = smoothStep(edge0: 0, edge1: taperLength, value: distanceToEnd)
            dab.opacity *= multiplier
            dab.size = max(state.minimumBrushSize, dab.size * max(multiplier, 0.35))
            return dab
        }
    }

    private func startTaperMultiplier(_ distance: Float) -> Float {
        let taperLength = max(state.settings.startTaperLength, 0)
        guard taperLength > 0 else { return 1 }
        return max(0.18, smoothStep(edge0: 0, edge1: taperLength, value: distance))
    }

    private func velocityAmount(at point: BrushPoint) -> Float {
        guard let lastPlacedPoint else { return 0 }
        let delta = distance(from: lastPlacedPoint.position, to: point.position)
        let deltaTime = max(point.timestamp - lastPlacedPoint.timestamp, 1.0 / 120.0)
        return min(max((delta / deltaTime) / 3200.0, 0), 1)
    }

    private func smoothStep(edge0: Float, edge1: Float, value: Float) -> Float {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return x * x * (3 - 2 * x)
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
