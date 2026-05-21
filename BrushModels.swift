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

enum BrushCategory: String, Codable, CaseIterable, Identifiable {
    case sketching
    case inking
    case painting
    case smudge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sketching: return "Sketching"
        case .inking: return "Inking"
        case .painting: return "Painting"
        case .smudge: return "Smudge"
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
    var isEraser: Bool = false
    var rotationMode: RotationMode = .followStroke

    enum CodingKeys: String, CodingKey {
        case spacing
        case flow
        case scatter
        case hardness
        case softness
        case rotationJitter
        case tiltInfluence
        case smudgeStrength
        case isSmudge
        case isEraser
        case rotationMode
    }

    init() {}

    init(
        spacing: Float = 0.15,
        flow: Float = 1.0,
        scatter: Float = 0.0,
        hardness: Float = 0.5,
        softness: Float = 0.0,
        rotationJitter: Float = 0.0,
        tiltInfluence: Float = 0.5,
        smudgeStrength: Float = 0.7,
        isSmudge: Bool = false,
        isEraser: Bool = false,
        rotationMode: RotationMode = .followStroke
    ) {
        self.spacing = spacing
        self.flow = flow
        self.scatter = scatter
        self.hardness = hardness
        self.softness = softness
        self.rotationJitter = rotationJitter
        self.tiltInfluence = tiltInfluence
        self.smudgeStrength = smudgeStrength
        self.isSmudge = isSmudge
        self.isEraser = isEraser
        self.rotationMode = rotationMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spacing = try container.decodeIfPresent(Float.self, forKey: .spacing) ?? 0.15
        flow = try container.decodeIfPresent(Float.self, forKey: .flow) ?? 1.0
        scatter = try container.decodeIfPresent(Float.self, forKey: .scatter) ?? 0.0
        hardness = try container.decodeIfPresent(Float.self, forKey: .hardness) ?? 0.5
        softness = try container.decodeIfPresent(Float.self, forKey: .softness) ?? 0.0
        rotationJitter = try container.decodeIfPresent(Float.self, forKey: .rotationJitter) ?? 0.0
        tiltInfluence = try container.decodeIfPresent(Float.self, forKey: .tiltInfluence) ?? 0.5
        smudgeStrength = try container.decodeIfPresent(Float.self, forKey: .smudgeStrength) ?? 0.7
        isSmudge = try container.decodeIfPresent(Bool.self, forKey: .isSmudge) ?? false
        isEraser = try container.decodeIfPresent(Bool.self, forKey: .isEraser) ?? false
        rotationMode = try container.decodeIfPresent(RotationMode.self, forKey: .rotationMode) ?? .followStroke
    }
}

struct BrushPreset: Identifiable {
    var id: String { name }
    var name: String
    var category: BrushCategory
    var isUserEditable: Bool
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
    var isEraser: Float
}
