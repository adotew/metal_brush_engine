#include <metal_stdlib>
using namespace metal;

// MARK: - Brush Shader

struct QuadVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct BrushVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float pressure;
    float hardness;
    float softness;
    float smudgeStrength;
    float4 color;
    float2 worldPos;
    float flow;
};

struct DabInstance {
    float2 center;
    float size;
    float rotation;
    float pressure;
    float hardness;
    float softness;
    float smudgeStrength;
    float4 color;
    float2 tiltScale;
    float flow;
    float _pad;
};

vertex BrushVertexOut brushVertex(
    QuadVertex in [[stage_in]],
    uint instanceID [[instance_id]],
    constant DabInstance *dabs [[buffer(1)]],
    constant float2 &viewportSize [[buffer(2)]]
) {
    DabInstance dab = dabs[instanceID];

    float2 scaled = in.position * dab.tiltScale;
    float c = cos(dab.rotation);
    float s = sin(dab.rotation);
    float2 rotated = float2(
        scaled.x * c - scaled.y * s,
        scaled.x * s + scaled.y * c
    );

    float2 pixelPos = dab.center + rotated * dab.size;
    float2 ndc = (pixelPos / viewportSize) * 2.0 - 1.0;

    BrushVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.pressure = dab.pressure;
    out.hardness = dab.hardness;
    out.softness = dab.softness;
    out.smudgeStrength = dab.smudgeStrength;
    out.color = dab.color;
    out.worldPos = pixelPos;
    out.flow = dab.flow;

    return out;
}

fragment float4 brushFragment(
    BrushVertexOut in [[stage_in]],
    constant float2 &viewportSize [[buffer(0)]],
    texture2d<float> brushStamp [[texture(0)]],
    texture2d<float> canvasBackup [[texture(1)]],
    sampler brushSampler [[sampler(0)]]
) {
    float4 brushAlpha = brushStamp.sample(brushSampler, in.texCoord);

    float alpha = brushAlpha.a * in.pressure * in.flow;

    // Edge falloff based on hardness
    float2 center = in.texCoord - 0.5;
    float dist = length(center) * 2.0;

    float hardnessFalloff;
    if (dist < in.hardness) {
        hardnessFalloff = 1.0;
    } else {
        float t = (dist - in.hardness) / max(0.01, 1.0 - in.hardness);
        hardnessFalloff = exp(-t * t * 5.0);
    }

    // Additional softness multiplier
    hardnessFalloff *= 1.0 - in.softness * dist;
    hardnessFalloff = saturate(hardnessFalloff);

    alpha *= hardnessFalloff;

    float3 finalColor = in.color.rgb;

    // Smudge: sample from canvas backup
    if (in.smudgeStrength > 0.0) {
        float2 canvasUV = in.worldPos / viewportSize;
        float4 canvasColor = canvasBackup.sample(brushSampler, canvasUV);
        finalColor = mix(in.color.rgb, canvasColor.rgb, in.smudgeStrength);
    }

    return float4(finalColor, alpha);
}

// MARK: - Display Passthrough Shader

struct PassthroughVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct PassthroughVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct DisplayUniforms {
    float2 scale;
    float2 translation;
};

vertex PassthroughVertexOut displayVertex(
    PassthroughVertexIn in [[stage_in]],
    constant DisplayUniforms &display [[buffer(1)]]
) {
    PassthroughVertexOut out;
    out.position = float4(in.position * display.scale + display.translation, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 displayFragment(
    PassthroughVertexOut in [[stage_in]],
    constant float &opacity [[buffer(0)]],
    texture2d<float> canvasTexture [[texture(0)]],
    sampler canvasSampler [[sampler(0)]]
) {
    float4 color = canvasTexture.sample(canvasSampler, in.texCoord);
    return float4(color.rgb * opacity, color.a * opacity);
}

// MARK: - Cursor Overlay Shader

struct CursorVertexOut {
    float4 position [[position]];
    float2 localPos;
    float2 ndcPos;
};

struct CursorUniforms {
    float2 center;   // in NDC
    float2 radius;   // in NDC
    float show;
    float padding;
};

vertex CursorVertexOut cursorVertex(
    QuadVertex in [[stage_in]],
    constant CursorUniforms &cursor [[buffer(1)]]
) {
    CursorVertexOut out;
    // Scale the [-1,1] quad by radius and translate to center (both NDC)
    float2 ndc = cursor.center + in.position * cursor.radius;
    out.position = float4(ndc, 0.0, 1.0);
    out.localPos = in.position; // [-1,1] across the quad, 0 at center
    out.ndcPos = ndc;           // NDC position for correct UV mapping
    return out;
}

fragment float4 cursorFragment(
    CursorVertexOut in [[stage_in]],
    constant CursorUniforms &cursor [[buffer(1)]],
    texture2d<float> canvasTexture [[texture(0)]],
    sampler canvasSampler [[sampler(0)]]
) {
    if (cursor.show < 0.5) { discard_fragment(); }

    // localPos ranges from -1 to 1 across the quad
    float dist = length(in.localPos);

    // Convert pixel thickness to NDC thickness
    float minRadiusNDC = min(cursor.radius.x, cursor.radius.y);
    float pixelThickness = 2.0; // 2px outer ring
    float ndcThickness = pixelThickness / max(minRadiusNDC * 1000.0, 1.0);
    ndcThickness = max(ndcThickness, 0.015);

    // ---- Outer black ring ----
    float outerRingDist = abs(dist - 1.0);
    float outerAlpha = 1.0 - smoothstep(0.0, ndcThickness * 1.3, outerRingDist);

    // ---- Inner white ring (slightly thinner, inset) ----
    float innerRingDist = abs(dist - (1.0 - ndcThickness * 0.3));
    float innerAlpha = 1.0 - smoothstep(0.0, ndcThickness * 0.6, innerRingDist);

    // ---- Center dot ----
    float dotDist = length(in.localPos);
    float dotAlpha = 1.0 - smoothstep(0.0, ndcThickness * 0.8, dotDist);

    // Combine: black outer, white inner, white dot
    float3 color = float3(0.0, 0.0, 0.0); // black
    float alpha = outerAlpha;

    if (innerAlpha > 0.01) {
        color = float3(1.0, 1.0, 1.0); // white
        alpha = max(alpha, innerAlpha);
    }

    if (dotAlpha > 0.01) {
        color = float3(1.0, 1.0, 1.0); // white center dot
        alpha = max(alpha, dotAlpha);
    }

    if (alpha < 0.01) { discard_fragment(); }

    return float4(color, alpha);
}
