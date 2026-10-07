# metal-intro

Native Apple Silicon Metal intro scaffold, sized for a 64 KiB budget.
The default mode is a compute path tracer with an SVGF-style spatiotemporal denoiser and continuous camera motion.

## Status

Working dev scaffold:

- builds with the Xcode Command Line Tools alone (no full Xcode, no Metal Toolchain);
- shaders are embedded in the binary and compiled at runtime (`newLibraryWithSource:`);
- `pt` mode (default): Cornell-style box, diffuse walls + chrome sphere + glass sphere + emissive sphere light; cosine-weighted diffuse with next-event estimation, exact-Fresnel dielectric, Russian roulette, per-sample firefly clamp;
- denoiser: G-buffer (normal + depth + reflection guide) -> temporal reprojection with a validated 4-tap history fetch (bilinear weights over normal/depth-verified taps, so edges cannot bleed), variance clipping and a neighbourhood min-max clamp against fresh fireflies, motion- and variance-adaptive history length -> three a-trous passes (steps 1/2/4) with variance-guided luminance, normal, depth and reflection-guide edge stopping;
- the window renders at half resolution by default (8 spp, linear upscale in the display pass) to afford the samples the denoiser needs; `--scale` tunes it;
- `--move` runs a continuous camera path instead of hard cuts, `--no-denoise` shows the raw image for comparison;
- FPS shown in the window title; offscreen modes print it;
- `--smoke` renders offscreen headlessly, `--shot` captures a PPM still at any `--size`;
- `sdf` mode keeps the original raymarched raster scene as a lighter fallback;
- `release.sh` produces a self-extracting file gated at 65536 bytes.

Not done yet (the interesting part): offline `metallib`, real compression, audio, and every byte-shaving trick. See Roadmap.

## Usage

```sh
./build.sh
out/demo                          # denoised path tracer, f fullscreen, p pause, ESC quit
out/demo --move                   # continuous camera motion
out/demo --scale 1.0 --spp 2      # native-res alternative (sharper, noisier in motion)
out/demo --no-denoise             # raw image, for comparison
out/demo --mode sdf               # raymarched raster mode
out/demo --smoke 60               # offscreen render + fps report
out/demo --shot shot.ppm 120 --size 2560x1440 --scale 0.5 --spp 8
python3 tools/ppm2png.py shot.ppm shot.png
./release.sh                      # out/demo64k, self-extracting, hard 64 KiB gate
```

## Design

Passes per frame (path tracer resolution = output * `--scale`, half by default in the window):

1. `cs_pathtrace` writes the frame radiance, a G-buffer (primary-hit normal and ray distance) and a reflection guide (distance to the first hit of one secondary mirrored/refracted ray).
2. `cs_temporal` reprojects the previous frame through the previous camera basis (world position from depth), fetches the history with bilinear weights over the four taps that pass `dot(n, n_prev) > 0.9` and `|depth - depth_prev| < 5%`, clips the new sample against the history's mean +/- 3 sigma and against the current-frame 3x3 min/max (speckle control, this is what kills fireflies at object silhouettes), then blends with `alpha = max(1/(len+1), motion- and variance-adaptive alpha)` and accumulates luminance moments for variance.
3. `cs_atrous` runs three 5x5 a-trous passes (steps 1, 2, 4) with weights `exp(-|dz|/(0.15 z)) * max(0, dot(n, n_k))^16 * exp(-|dL|/sigmaL) * exp(-|dGuide|/(0.1 guide))`. The reflection guide keeps the filter from smearing mirror and glass content.
4. `fs_display` upscales (linear) and applies exposure + ACES + gamma.

Textures ping-pong for history, G-buffer and filter targets; history resets on camera cuts, resize, and first frame. The camera is a hard cut every 6 s between four shots, or an analytic path with `--move`.

Gotchas that cost time, worth knowing:

- Framebuffer and texture y axes point down in Metal; camera rays flip `uv.y`.
- The ray direction is `normalize(uv.x*right + uv.y*up + 1.7*forward)`, so recovering screen coordinates from a world position divides by `z` and **multiplies by 1.7** — dividing by 1.7 too teleports every reprojected pixel toward the screen center.
- The C `PTUniforms` must use `simd_float2` / `simd_float4` for every vector field: plain `float[4]` has 4-byte alignment and silently shifts every field after it against MSL's 16-byte vector alignment.
- Uniform contract (128 bytes, matches between MSL and the host):

  ```c
  struct PTUniforms {
      simd_float2 resolution; simd_float2 outputResolution; float time; float frame;
      simd_float4 cameraPos; simd_float4 cameraTarget;
      simd_float4 prevCameraPos; simd_float4 prevCameraTarget;
      uint32_t frameSeed; uint32_t samplesPerFrame;
      uint32_t resetHistory; uint32_t filterStep;
      float exposure; float pad0, pad1, pad2;
  };
  ```

## Measured (M4 Pro)

- 2560x1440 output, moving camera, half-res 8 spp with denoiser: ~116 fps offscreen; full-res 2 spp: ~75 fps. Windowed is display-capped at 60 fps.
- A/B on a flat wall at 1280x720, median neighbor difference: raw 2 spp = 52/255, denoised = 0/255.
- Packed release artifact: 25.6 KB, 39.0% of the 64 KiB budget with the whole path tracer and denoiser embedded.

## 64k roadmap (toward the Revision 2027 combo)

1. **Offline shader compilation.** Full Xcode + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), build a `.metallib`, embed it. Runtime compilation is a dev convenience, not a release path.
2. **Compression.** gzip is only the safe first step. A custom LZ + range coder shaves the constant overhead; study `powernap`.
3. **Denoiser refinements.** Albedo demodulation and specular-specific filtering; the reflection guide fixed most of the mirror smearing, the remaining softness is in the mirror interior.
4. **ML denoiser.** A tiny MLP (weights trained offline, embedded) replacing the a-trous passes is the natural "AI" step.
5. **Synth.** GPU or CoreAudio synthesis, FFT-driven visuals.
6. **Machine personalization.** powernap-style: username, wallpaper, screen contents baked into the scene.
7. **Mach-O diet and CI.** `-Os`, `strip -x`, dead-strip unused AppKit paths, inspect with `size -m` / `otool`, run `build.sh --smoke` on a `macos-14` GitHub Actions runner.

## macOS gotchas

- **Signing.** arm64 binaries must carry at least an ad-hoc signature; a stripped release binary needs `codesign --force -s -` again, which costs a few hundred bytes.
- **Gatekeeper.** macOS 15.5+ quarantines downloaded files aggressively. A demo handed to someone else will need right-click -> Open the first time, or `xattr -d com.apple.quarantine <file>`. Put a note in your `.nfo`/`.diz`.

## References

- [SVGF](https://research.nvidia.com/publication/2017-07_spatiotemporal-variance-guided-filtering-real-time-reconstruction-path-traced) — Schied et al., the denoiser this follows.
- [powernap](https://github.com/lovelaced/powernap) — 64k intro for Apple Silicon, open source end to end.
- *Umbraplasma* (mgt ^ JackPearse, Revision 2026) — 64k intro in the PC compo, notes on Gatekeeper and Mach-O size costs.
- [Roquefort / Feenikslintu](https://github.com/Bercon/feenikslintu) — WebGPU compute-shader demos, if you want a portable variant of the same shader work.
