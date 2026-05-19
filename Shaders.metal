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
    int brushType;
    float4 color;
    float2 worldPos;
};

struct DabInstance {
    float2 center;
    float size;
    float rotation;
    float pressure;
    float hardness;
    float softness;
    float smudgeStrength;
    int brushType;
    float4 color;
    float _pad; // align to 16 bytes
};

vertex BrushVertexOut brushVertex(
    QuadVertex in [[stage_in]],
    uint instanceID [[instance_id]],
    constant DabInstance *dabs [[buffer(1)]],
    constant float2 &viewportSize [[buffer(2)]]
) {
    DabInstance dab = dabs[instanceID];

    float c = cos(dab.rotation);
    float s = sin(dab.rotation);
    float2 rotated = float2(
        in.position.x * c - in.position.y * s,
        in.position.x * s + in.position.y * c
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
    out.brushType = dab.brushType;
    out.color = dab.color;
    out.worldPos = pixelPos;

    return out;
}

fragment float4 brushFragment(
    BrushVertexOut in [[stage_in]],
    constant float2 &viewportSize [[buffer(0)]],
    texture2d<float> brushSoft [[texture(0)]],
    texture2d<float> brushHard [[texture(1)]],
    texture2d<float> brushFlat [[texture(2)]],
    texture2d<float> brushTextured [[texture(3)]],
    texture2d<float> canvasBackup [[texture(4)]],
    sampler brushSampler [[sampler(0)]]
) {
    float4 brushAlpha;
    switch (in.brushType) {
        case 0: brushAlpha = brushSoft.sample(brushSampler, in.texCoord); break;
        case 1: brushAlpha = brushHard.sample(brushSampler, in.texCoord); break;
        case 2: brushAlpha = brushFlat.sample(brushSampler, in.texCoord); break;
        case 3: brushAlpha = brushTextured.sample(brushSampler, in.texCoord); break;
        default: brushAlpha = brushSoft.sample(brushSampler, in.texCoord); break;
    }

    float alpha = brushAlpha.a * in.pressure;

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

vertex PassthroughVertexOut displayVertex(
    PassthroughVertexIn in [[stage_in]]
) {
    PassthroughVertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 displayFragment(
    PassthroughVertexOut in [[stage_in]],
    texture2d<float> canvasTexture [[texture(0)]],
    sampler canvasSampler [[sampler(0)]]
) {
    return canvasTexture.sample(canvasSampler, in.texCoord);
}
