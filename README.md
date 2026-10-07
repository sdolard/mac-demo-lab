# mac-demo-lab

Low-level GPU demos from a Mac, aimed at demoscene competitions.

No emulators, no porting: everything here runs natively on Apple Silicon.

| Track | What | Compete in |
|---|---|---|
| [`shader-showdown/`](shader-showdown/) | Live-coded GLSL with Bonzomatic, plus a zero-install WebGL2 practice pad | Revision Shader Showdown / Shader Royale, livecoding events |
| [`metal-intro/`](metal-intro/) | Native Apple Silicon Metal scaffold: compute path tracer with an SVGF-style denoiser and continuous camera motion, heading for a 4k/64k intro | 4k/64k intro compos, Wild compo |

## Quickstart

Shader battle practice (no install):

```sh
open shader-showdown/pad/index.html
```

Full Bonzomatic setup (the actual compo tool):

```sh
sh shader-showdown/setup-bonzomatic.sh
```

Metal intro scaffold:

```sh
sh metal-intro/build.sh
metal-intro/out/demo                  # denoised path tracer, f fullscreen, p pause, ESC quit
metal-intro/out/demo --move           # continuous camera motion
metal-intro/out/demo --no-denoise     # raw 2 spp for comparison
metal-intro/out/demo --mode sdf       # raymarched raster fallback
metal-intro/out/demo --smoke          # offscreen render test, prints fps
metal-intro/out/demo --shot p.ppm 240 # capture a still, then tools/ppm2png.py
sh metal-intro/release.sh             # self-extracting pack, gated at 65536 bytes
```

## Where to compete

- [Revision](https://revision-party.net/) (Saarbrucken, April) — Shader Showdown, Shader Royale, 4k/64k intros; macOS entries have run in the 64k compo.
- [Assembly](https://assembly.org/) (Helsinki, summer) — 4k intros, and browser-based entries are explicitly accepted.
- [Lovebyte](https://lovebyte.party/) (online, February) — byte battles, sizecoding across platforms.
- [livecode.demozoo.org](https://livecode.demozoo.org/) — livecoding events calendar, qualifiers, VODs.

## References

- [powernap](https://github.com/lovelaced/powernap) — open-source 64k intro for Apple Silicon (Metal + synth + packing workflow).
- *Umbraplasma* (mgt ^ JackPearse, Revision 2026) — 64k intro for Apple Silicon, ran in the PC-64k compo.
- [Bonzomatic](https://github.com/Gargaj/Bonzomatic) — the livecoding tool used by Shader Showdown.
- [Feenikslintu](https://github.com/Bercon/feenikslintu) — 4k executable graphics via WebGPU compute shaders.

## Status

Scaffold. The Metal renderer embeds MSL source and compiles it at runtime so it builds with the Xcode Command Line Tools alone; the path tracer with the SVGF-style denoiser runs at ~275 fps offscreen (display-capped at 60 windowed) on an M4 Pro, and its packed release fits in 36% of the 64 KiB budget. The size-coding path (offline `metallib`, self-compression, synth) is the roadmap; see `metal-intro/README.md`.
