import AppKit
import Metal

struct BrushPoint {
    var position: SIMD2<Float>
    var pressure: Float
    var size: Float
    var tiltX: Float
    var tiltY: Float
    var azimuth: Float
    var timestamp: Float
    var rotation: Float
}

enum RotationMode: Int, Codable, CaseIterable, Identifiable {
    case followStroke = 0
    case fixed = 1
    case random = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .followStroke: return "Follow Stroke"
        case .fixed: return "Fixed"
        case .random: return "Random"
        }
    }
}

struct BrushSettings: Codable {
    var spacing: Float = 0.15
    var flow: Float = 1.0
    var scatter: Float = 0.0
    var hardness: Float = 0.5
    var softness: Float = 0.0
    var rotationJitter: Float = 0.0
    var tiltInfluence: Float = 0.5
    var smudgeStrength: Float = 0.7
    var isSmudge: Bool = false
    var rotationMode: RotationMode = .followStroke
}

struct BrushPreset: Identifiable {
    let id = UUID()
    let name: String
    let texture: MTLTexture
    let thumbnail: NSImage
    var settings: BrushSettings
}

struct DabInstance {
    var center: SIMD2<Float>
    var size: Float
    var rotation: Float
    var pressure: Float
    var hardness: Float
    var softness: Float
    var smudgeStrength: Float
    var color: SIMD4<Float>
    var tiltScale: SIMD2<Float>
    var flow: Float
    var _pad: Float = 0
}
