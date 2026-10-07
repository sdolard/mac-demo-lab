# metal-intro

Native Apple Silicon Metal intro scaffold, sized for a 64 KiB budget.
The default mode is a compute-shader progressive path tracer.

## Status

Working dev scaffold:

- builds with the Xcode Command Line Tools alone (no full Xcode, no Metal Toolchain);
- shaders are embedded in the binary and compiled at runtime (`newLibraryWithSource:`);
- `pt` mode (default): Cornell-style box, diffuse walls + chrome sphere + glass sphere + emissive sphere light, next-event estimation, Russian roulette, per-sample firefly clamp, progressive accumulation in an `rgba32f` texture;
- `sdf` mode: the original raymarched raster scene, kept as a lighter fallback;
- `--smoke` renders offscreen headlessly, `--shot` captures a PPM still;
- `release.sh` produces a self-extracting file gated at 65536 bytes.

Not done yet (the interesting part): offline `metallib`, real compression, denoiser, synth, and every byte-shaving trick. See Roadmap.

## Usage

```sh
./build.sh
out/demo                          # path tracer: f fullscreen, p pause, ESC quit
out/demo --mode sdf               # raymarched raster mode
out/demo --spp 8                  # samples per dispatch (default 4)
out/demo --smoke 8                # offscreen render, exits 0 on success
out/demo --shot shot.ppm 240      # capture shot 0: 240 frames x 16 spp = 3840 spp
python3 tools/ppm2png.py shot.ppm shot.png
./release.sh                      # out/demo64k, self-extracting, hard 64 KiB gate
```

## Design

- `cs_pathtrace`: 8x8 threadgroups over an `rgba32f` `read_write` accumulation texture (incremental mean, `1/(n+1)` blend). The camera is a hard cut every 6 s between four shots; each static shot keeps refining until the cut.
- `vs_fullscreen` / `fs_display`: present pass that reads the accumulation and applies exposure + ACES + gamma.
- Estimator: cosine-weighted diffuse with next-event estimation against the emissive sphere, perfect mirror, dielectric glass (exact Fresnel + refraction), 8 bounces max, Russian roulette after 3, and a per-sample firefly clamp (6.0) to tame the `1/d^2` spikes from the small key light.
- Uniform contract (64 bytes, matches between MSL and the host):

  ```c
  struct PTUniforms {
      float2 resolution; float time; float frame;
      float4 cameraPos; float4 cameraTarget;
      uint32_t sampleIndex; uint32_t frameSeed; float exposure; uint32_t samplesPerFrame;
  };
  ```

- Metal gotcha: framebuffer and texture y axes point down, so camera rays flip `uv.y`. If the image looks upside down, that is why.

Measured on an M4 Pro: a 1280x720 dispatch costs ~19 ms at 16 spp (~5 ms at 4 spp, comfortably inside a 60 fps budget). An offscreen 240-frame x 16 spp still (3840 spp) renders in ~5 s and sits at a 2/255 noise floor; 15360 spp reaches 1/255. The packed release artifact is 19 KB (29% of the 64 KiB budget) with the whole path tracer embedded.

## 64k roadmap (toward the Revision 2027 combo)

1. **Offline shader compilation.** Install full Xcode + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), compile `shader.metal` to a `.metallib` with `xcrun -sdk macosx metal` / `metallib`, embed the library. Runtime compilation is a dev convenience, not a release path.
2. **Compression.** gzip is only the safe first step. A custom LZ + range coder shaves the constant overhead further; study `powernap` for a worked example.
3. **Temporal reprojection.** Accumulate across camera motion so shots can move continuously instead of hard-cutting.
4. **Denoiser.** SVGF-style à-trous or a tiny MLP: turns 1 spp into clean frames. This is the real "wow" and the bridge to the ML angle.
5. **Synth.** GPU or CoreAudio synthesis, FFT-driven visuals.
6. **Machine personalization.** powernap-style: username, wallpaper, screen contents baked into the scene.
7. **Mach-O diet and CI.** `-Os`, `strip -x`, dead-strip unused AppKit paths, inspect with `size -m` / `otool`, and run `build.sh --smoke` on a `macos-14` GitHub Actions runner.

## macOS gotchas

- **Signing.** arm64 binaries must carry at least an ad-hoc signature; a stripped release binary needs `codesign --force -s -` again, which costs a few hundred bytes.
- **Gatekeeper.** macOS 15.5+ quarantines downloaded files aggressively. A demo handed to someone else will need right-click -> Open the first time, or `xattr -d com.apple.quarantine <file>`. Put a note in your `.nfo`/`.diz`.
- **Runtime shader compilation** needs no Xcode, but do not ship it: it embeds the MSL source and risks driver differences on the target machine.

## References

- [powernap](https://github.com/lovelaced/powernap) — 64k intro for Apple Silicon, open source end to end.
- *Umbraplasma* (mgt ^ JackPearse, Revision 2026) — 64k intro in the PC compo, notes on Gatekeeper and Mach-O size costs.
- [Roquefort / Feenikslintu](https://github.com/Bercon/feenikslintu) — WebGPU compute-shader demos, if you want a portable variant of the same shader work.
