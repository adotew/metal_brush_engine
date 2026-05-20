# Smudge Brush Research Notes

## What We Learned from Krita's Source Code

### Core Architecture

Krita's Color Smudge Brush Engine (`kis_colorsmudgeop.cpp`) is **not** a simple shader trick. It is a full CPU-side paint operation that uses a sophisticated overlay buffer system:

1. **Per-dab read-back**: Before every dab, Krita copies the affected canvas regions into an overlay paint device (`KisOverlayPaintDeviceWrapper::readRects()`). After blending, it writes results back (`writeRects()`). Each dab sees the previous dab's result because the overlay is refreshed every dab.

2. **Strategy pattern**: Krita routes smudge through dedicated strategy classes depending on brush tip type, mode, and options:
   - `KisColorSmudgeStrategyMask` — for normal brush tips
   - `KisColorSmudgeStrategyStamp` — for image stamp brushes
   - `KisColorSmudgeStrategyLightness` — for lightness map brushes
   - `KisColorSmudgeStrategyMaskLegacy` — old engine fallback

3. **Two distinct modes**:
   - **Smearing**: Copies pixels from the previous brush position to the current one. Uses `COMPOSITE_OVER` or `COMPOSITE_COPY` blending. Krita recommends very low spacing (0.05 or less) for smooth results.
   - **Dulling**: Samples the color under the dab (optionally with a radius), fills the dab with that color, then applies foreground paint on top. Uses a separate sampling step (`sampleDullingColor`).

4. **First-dab skip**: Krita explicitly skips rendering the first dab of a smudge stroke. It only records the position so the *second* dab has a valid source position to sample from:
   ```cpp
   if (m_firstRun) {
       m_firstRun = false;
       return spacingInfo;  // No painting
   }
   ```

5. **Source rectangle calculation**: The source footprint is the destination footprint shifted by the movement vector:
   ```cpp
   QRect srcDabRect = m_dstDabRect.translated((m_lastPaintPos - newCenterPos).toPoint());
   ```

6. **Color Rate vs Smudge Rate separation**: Krita separates these so a pure smudge can move existing color without injecting foreground paint. `colorRateOpacity = colorRate * colorRate * opacity`.

7. **Alpha handling**: Krita's smear composite op defaults to `COMPOSITE_COPY` when `smearAlpha` is enabled, or `COMPOSITE_OVER` when disabled. The canvas uses a precise color space (often 16-bit per channel) to prevent banding during repeated smudging.

### Key Implementation Details from `KisColorSmudgeStrategyBase.cpp`

```cpp
// Smear mode: blend source over destination
void blendInBackgroundWithSmearing(dst, src, srcRect, dstRect, smudgeRateOpacity) {
    if (smearOp == COMPOSITE_COPY && smudgeRateOpacity == 1.0) {
        src->readBytes(dst->data(), srcRect);  // Full replacement
    } else {
        dst = read(canvas, dstRect);
        temp = read(canvas, srcRect);
        dst = composite(dst, temp, smudgeRateOpacity);  // Partial blend
    }
}

// Dulling mode: fill with sampled color, then blend
void blendInBackgroundWithDulling(dst, dstRect, dullingColor, dullingRateOpacity) {
    if (smearOp == COMPOSITE_COPY && dullingRateOpacity == 1.0) {
        dst->fill(dst->bounds(), dullingColor);
    } else {
        dst = read(canvas, dstRect);
        dst = composite(dst, dullingColor, dullingRateOpacity);
    }
}
```

### Why Our Implementations Failed

**Attempt 1 (instanced smudge with canvasBackup)**:
- Copied the entire canvas to backup once per frame
- All smudge dabs in a stroke read from the same backup
- Result: no sequential feedback, short inconsistent smear

**Attempt 2 (per-dab temp texture)**:
- Rendered each smudge dab to a small temp texture, then blitted back
- Passed temp texture size as viewportSize, but sourceWorldPos was in canvas coordinates
- Result: UV coordinates were completely wrong, sampling garbage
- Blit replaced pixels instead of compositing, destroying existing paint

**Attempt 3 (per-dab union-rect blit + render)**:
- Correctly computed union of source and destination rects
- Blitted union rect from canvas to backup before each dab
- Used premultiplied alpha but the display shader and blend pipeline weren't fully aligned
- The smudge math in the shader (`mix(dstColor, srcColor, smudgeRate)`) was an oversimplification of Krita's composite op approach
- Still had subtle alpha blending artifacts because premultiplied alpha requires careful handling throughout the entire pipeline

### What a Correct Implementation Would Need

1. **CPU-side per-dab canvas read-back** — Metal GPU shaders cannot safely read from a texture they are simultaneously writing to. You need either:
   - A separate render pass per dab (expensive)
   - A compute shader with explicit memory barriers
   - A double-buffered canvas texture that ping-pongs each dab

2. **Proper composite operations** — Not simple `mix()`. Krita uses full alpha compositing with separate color and alpha operations. For smear with `COMPOSITE_OVER`:
   ```
   out.rgb = src.rgb * src.a * rate + dst.rgb * dst.a * (1 - src.a * rate)
   out.a = src.a * rate + dst.a * (1 - src.a * rate)
   ```

3. **16-bit color space** — Repeated smudging on 8-bit textures causes visible banding. Krita promotes to 16-bit internally.

4. **First-dab skip** — Essential for smearing mode so the stroke origin doesn't paint a self-sampling dot.

5. **Separate source/destination UV math** — The source sample point must be in canvas coordinates, not dab-local coordinates.

6. **Dulling color sampling** — For dulling mode, you need to sample an average color from under the dab, optionally with a radius. This requires a separable sampling pass or compute reduction.

### Recommended Path Forward

A high-quality smudge brush on Metal would need:
- A compute-based approach or ping-pong texture double-buffering
- A separate fragment function for smear vs dulling
- Proper alpha compositing math, not simple lerp
- 16-bit float canvas textures to prevent banding
- Consider using `MTLRenderCommandEncoder`'s tile shaders or memoryless render targets for performance

For this project's current scope, a basic **eraser** is a more achievable and immediately useful feature.
