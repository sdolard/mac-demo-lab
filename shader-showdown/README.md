# shader-showdown

Live-coded GLSL, in the format used by demoscene shader battles.

The rule of the game (Revision Shader Showdown): 25 minutes, code from scratch, GLSL, in Bonzomatic, audience votes. Qualifiers often run remote, so you can compete from a Mac — shaders are GPU-agnostic.

## Setup

```sh
sh setup-bonzomatic.sh
```

This clones [Bonzomatic](https://github.com/Gargaj/Bonzomatic) into `vendor/` and builds the macOS app (`vendor/Bonzomatic/build/Bonzomatic.app`). Requires `cmake` (`brew install cmake`).

Bonzomatic injects the standard livecoding environment: `fragCoord`, `fragColor`, `iResolution`, `iTime`, `iTimeDelta`, `iFrame`, `iMouse`, FFT textures (`texFFT`, `texFFTSmoothed`), and the provided textures (`texChecker`, `texNoise`, ...). You write a plain `void main()` — see `shaders/template.glsl`.

Keys: `F5`/`Ctrl-R` recompile, `F11`/`Cmd-F` hide editor, `F2` texture preview.

## Practice without installing anything

```sh
open pad/index.html
```

A self-contained WebGL2 pad that mimics the Bonzomatic environment (same uniform/macro names, so a shader written in the pad runs in Bonzomatic). Tab toggles the editor, `Cmd/Ctrl-Enter` recompiles, `Space` pauses, `P` cycles presets, `R` resets time. Sources are kept in `localStorage`.

## Routine that works

1. Offline: sketch one primitive per session in the pad (raymarch, noise, domain warp, palette).
2. Live: open Bonzomatic, hide everything else, write the same effect from scratch against a timer — 25 min, no looking things up.
3. Bank idioms you can type from muscle memory: `sdSphere`, rotation, `hash`, `fbm`, palette, a camera rig, a lighting block.

Log your Battles (theme, date, time, votes) in `battles.md` if you want to track progress.

## Files

- `shaders/template.glsl` — minimal Bonzomatic-compatible starter.
- `shaders/warmup.glsl` — a small raymarched scene you should be able to re-derive from memory.
- `pad/index.html` — offline practice pad (WebGL2, no dependencies).
- `setup-bonzomatic.sh` — clone + build Bonzomatic on macOS.

## References

- [livecode.demozoo.org](https://livecode.demozoo.org/) — events, qualifiers, replays.
- [Bonzomatic wiki: how to set up a live coding compo](https://github.com/Gargaj/Bonzomatic/wiki/How-to-set-up-a-Live-Coding-compo).
- [The Book of Shaders](https://thebookofshaders.com/) and [iquilezles.org](https://iquilezles.org/articles/) — fundamentals and SDF canon.
