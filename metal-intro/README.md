# metal-intro

Native Apple Silicon Metal intro scaffold, sized for a 64 KiB budget.
The default mode is a compute path tracer with an SVGF-style spatiotemporal denoiser and continuous camera motion.

## Status

Working dev scaffold:

- builds with the Xcode Command Line Tools alone (no full Xcode, no Metal Toolchain);
- shaders are embedded in the binary and compiled at runtime (`newLibraryWithSource:`);
- `pt` mode (default): Cornell-style box, diffuse walls + chrome sphere + glass sphere + emissive sphere light; cosine-weighted diffuse with next-event estimation, exact-Fresnel dielectric, Russian roulette, per-sample firefly clamp, 2 spp per dispatch;
- denoiser: G-buffer (normal + depth) -> temporal reprojection accumulation (normal/depth validation, 16-frame history cap) -> three a-trous passes (steps 1/2/4) with variance-guided luminance, normal and depth edge stopping;
- `--move` runs a continuous camera path instead of hard cuts, `--no-denoise` shows the raw 2 spp image for comparison;
- FPS shown in the window title; offscreen modes print it;
- `--smoke` renders offscreen headlessly, `--shot` captures a PPM still;
- `sdf` mode keeps the original raymarched raster scene as a lighter fallback;
- `release.sh` produces a self-extracting file gated at 65536 bytes.

Not done yet (the interesting part): offline `metallib`, real compression, audio, and every byte-shaving trick. See Roadmap.

## Usage

```sh
./build.sh
out/demo                          # denoised path tracer, f fullscreen, p pause, ESC quit
out/demo --move                   # continuous camera motion
out/demo --no-denoise             # raw 2 spp, for comparison
out/demo --spp 1                  # samples per dispatch (default 2)
out/demo --mode sdf               # raymarched raster mode
out/demo --smoke 60               # offscreen render + fps report
out/demo --shot shot.ppm 120      # capture shot 0 (add --move for a moving frame)
python3 tools/ppm2png.py shot.ppm shot.png
./release.sh                      # out/demo64k, self-extracting, hard 64 KiB gate
```

## Design

Passes per frame (all at render resolution):

1. `cs_pathtrace` writes the frame radiance plus a G-buffer (primary-hit normal and ray distance).
2. `cs_temporal` reprojects the previous frame through the previous camera basis (world position from depth), validates with `dot(n, n_prev) > 0.9` and `|depth - depth_prev| < 5%`, then blends with `alpha = max(1/(len+1), 1/17)` and accumulates luminance moments for variance.
3. `cs_atrous` runs three 5x5 a-trous passes (steps 1, 2, 4) with weights `exp(-|dz|/(0.15 z)) * max(0, dot(n, n_k))^16 * exp(-|dL|/(0.6 sqrt(var) + 0.02))`.
4. `fs_display` applies exposure + ACES + gamma.

Textures ping-pong for history, G-buffer and filter targets; history resets on camera cuts, resize, and first frame. The camera is a hard cut every 6 s between four shots, or an analytic path with `--move`.

Gotchas that cost time, worth knowing:

- Framebuffer and texture y axes point down in Metal; camera rays flip `uv.y`.
- The ray direction is `normalize(uv.x*right + uv.y*up + 1.7*forward)`, so recovering screen coordinates from a world position divides by `z` and **multiplies by 1.7** — dividing by 1.7 too teleports every reprojected pixel toward the screen center.
- Uniform contract (112 bytes, matches between MSL and the host):

  ```c
  struct PTUniforms {
      float2 resolution; float time; float frame;
      float4 cameraPos; float4 cameraTarget;
      float4 prevCameraPos; float4 prevCameraTarget;
      uint32_t frameSeed; uint32_t samplesPerFrame;
      uint32_t resetHistory; uint32_t filterStep;
      float exposure; float pad0, pad1, pad2;
  };
  ```

## Measured (M4 Pro, 1280x720)

- 2 spp + full denoiser: ~275 fps offscreen; windowed is display-capped at 60 fps.
- A/B on a flat wall, median neighbor difference: raw 2 spp = 52/255, denoised = 0/255, static and moving.
- Packed release artifact: 23.8 KB, 36.3% of the 64 KiB budget with the whole path tracer and denoiser embedded.

## 64k roadmap (toward the Revision 2027 combo)

1. **Offline shader compilation.** Full Xcode + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), build a `.metallib`, embed it. Runtime compilation is a dev convenience, not a release path.
2. **Compression.** gzip is only the safe first step. A custom LZ + range coder shaves the constant overhead; study `powernap`.
3. **Denoiser refinements.** Albedo demodulation, variance clamping, and a reflection guide (or specular-specific filtering) to sharpen the chrome sphere; the spatial filter currently softens mirror content.
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
