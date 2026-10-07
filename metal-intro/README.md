# metal-intro

Native Apple Silicon Metal intro scaffold, sized for a 64 KiB budget.

## Status

Working dev scaffold:

- builds with the Xcode Command Line Tools alone (no full Xcode, no Metal Toolchain);
- the shader in `src/shader.metal` is compiled at runtime (`newLibraryWithSource:`) and embedded in the binary;
- `--smoke` renders frames offscreen, so the whole thing is testable headlessly;
- `release.sh` produces a self-extracting file gated at 65536 bytes.

Not done yet (the interesting part): offline `metallib`, real compression, synth, and every byte-shaving trick. See Roadmap.

## Usage

```sh
./build.sh
out/demo                 # dev window: f fullscreen, p pause, ESC quit
out/demo --fullscreen
out/demo --smoke         # offscreen render, exits 0 on success
./release.sh             # out/demo64k, self-extracting, hard 64 KiB gate
```

## Design

- `vs_fullscreen` draws a fullscreen triangle from `vertexID`; `fs_scene` is the whole intro.
- Uniform contract (16 bytes, matches between MSL and the host):

  ```c
  struct Uniforms { float2 resolution; float time; float frame; };
  ```

- The camera rig, SDF scene, lighting, tonemapping and film grain all live in the fragment shader. That is the material you will be fighting in a size-coded compo, so keep it in one place.

## 64k roadmap

1. **Offline shader compilation.** Install full Xcode + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), compile `shader.metal` to `.metallib` with `xcrun -sdk macosx metal` / `metallib`, embed the library. Runtime compilation is a dev convenience, not a release path.
2. **Compression.** gzip is only the safe first step (stock `gunzip` must exist on the target). A custom LZ + range coder shaves the constant overhead further; study `powernap` for a worked example.
3. **Synth.** Start with a tiny pattern-based softsynth writing into an `AVAudioEngine`/CoreAudio buffer; prerendered PCM is cheaper in code but costs bytes after compression.
4. **Mach-O diet.** `-Os`, `strip -x`, dead-strip unused AppKit paths, consider building the window with the runtime ObjC APIs instead of linking all of Cocoa, and inspect with `size -m`, `otool`, `dyld_info`.
5. **CI.** GitHub Actions `macos-14` (arm64) runner executing `build.sh --smoke` and enforing the size gate on `release.sh`.

## macOS gotchas

- **Signing.** arm64 binaries must carry at least an ad-hoc signature; a stripped release binary needs `codesign --force -s -` again, which costs a few hundred bytes.
- **Gatekeeper.** macOS 15.5+ quarantines downloaded files aggressively. A demo handed to someone else will need right-click → Open the first time, or `xattr -d com.apple.quarantine <file>`. Party organizers have started documenting this; put a note in your `.nfo`/`.diz`.
- **Runtime shader compilation** needs no Xcode, but do not ship it: it embeds the MSL source (gzip eats most of it, but still) and risks driver differences on the target machine.

## References

- [powernap](https://github.com/lovelaced/powernap) — 64k intro for Apple Silicon, open source end to end.
- *Umbraplasma* (mgt ^ JackPearse, Revision 2026) — 64k intro in the PC compo, notes on Gatekeeper and Mach-O size costs.
- [Roquefort / Feenikslintu](https://github.com/Bercon/feenikslintu) — WebGPU compute-shader demos, if you want a portable variant of the same shader work.
