# samport

**samport** runs the Xbox Series build of the game natively on Windows PCs with
NVIDIA graphics cards, from game files you supply yourself.

**This repository contains no game files or assets.** You need your own copy
of the game. Not affiliated with or endorsed by its developer or publisher.

## Status (2026-11-25)

Tested on Windows 11 with an **NVIDIA GeForce RTX 3070 ti** (8 GB):

| | |
|---|---|
| Boot, first-boot screens, intro, opening credits | works |
| Prologue | playable from the cell to the boat chase: cell, cafeteria, robbery, police chase (wanted level, minimap), boat, binoculars |
| Stability | 1 h 30 min+ in one session without a crash |
| Frame rate | 1-3 fps in the world (the first run is slower while shaders translate; they are cached after that) |
| Known problems | anything in shadow is black and bright scenes overexpose (the game's ray-traced lighting does not run yet); some blocky artifacts; boats sit low in the water |

## Requirements

- Windows 10/11 x64, a CPU with AVX2
- A Direct3D 12 GPU with shader model 6.6 and mesh shaders (NVIDIA RTX 20 series or newer)
- Rust (the version in `rust-toolchain.toml`)
- Several GB of free Windows commit memory (raise the paging file if `crashes.log` reports error 1455)

## Build

```powershell
cargo build --release -p victory
```

## Play

```powershell
powershell -ExecutionPolicy Bypass -File scripts\play.ps1 -Game "<your game folder>\<the game's exe>"
```

`scripts\play.ps1` keeps the shader cache and saves in folders you choose
(`-Cache`, `-Data`) and presses no buttons for you. Controller: XInput pads
(a DualShock/DualSense through DS4Windows works). With no pad connected the
keyboard acts as one while the game window has focus.

## Faster settings (optional, off by default)

`VICTORY_RELAY=2`, or `VICTORY_LATE_WAIT=3 VICTORY_WIDE_BACK=1` cut frame
time on the test machines. Set them in PowerShell before running the script.

## Debugging switches

| Switch | Effect |
|---|---|
| `VICTORY_CAPTURE=<dir>` + `VICTORY_CAPTURE_FRAMES=<list>` | save those frames as PNG (diagnostics build) |
| `VICTORY_KEYS=30:Enter,35:X` | press keys at those seconds (diagnostics build) |
| `VICTORY_D3D12_DRED=1` | on a GPU failure, report the commands in flight |
| `VICTORY_PIPELINE_WAIT_MS=24` | shorter per-frame wait for pipelines still being built |

Diagnostics build: `cargo build --profile diag -p victory --features diagnostics`

## samport additions (diagnostics)

`scripts\debug.ps1` runs the diagnostics build with the log shown and saved in
`%TEMP%` (`ztrx-diag.log`, plus `-summary.txt` and `-tail.txt`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\debug.ps1 -Game "<your game folder>\<the game's exe>"
```

| Switch / variable | Effect |
|---|---|
| `-TexturePct N` / `VICTORY_TEXTURE_PCT` (50-98, default 90) | share of the card's memory budget in use before textures picked by index wait; a `card memory for texture copies` line every 5 s shows budget, use and texture copies |
| `-Builder` | runs the ray-tracing structure builder in quarantine (`VICTORY_BVH_BUILDER=1 VICTORY_BVH_QUARANTINE=1`); a run that keeps it off names each program missing |
| `-FirstLaneLocal` / `VICTORY_FIRSTLANE_LOCAL=1` | approximate: a first-lane read where not every lane runs, in a 64-lane program split into two 32-lane halves, takes each half's own first lane. Lets all 53 builder programs translate. **Only with quarantine** |
| `-NamedWrites` / `VICTORY_MEMORY_WRITES=named` | experimental: a shader that uses raw addresses declares written only the memory its dispatch names, not every copy; with the builder on, snapshots of every copy cost ~1.9 s a frame. Stores through pointers read out of memory into unnamed copies are then not copied back |
| `-NoQuarantine` | builder output reaches game memory. **Do not use yet**: with `-FirstLaneLocal` the game crashed within seconds, reading float infinities as pointers |
| `-WaveWhy` / `VICTORY_WAVE_WHY=1` | prints why each 64-lane retry fails (`WAVE64-RETRY`); part of the shader cache key |
| overlap / `VICTORY_RELAY=2` | **default in `play.ps1` (`-Relay 0` off) and `debug.ps1` (`-NoFast` off)**: the card runs a submission while the CPU prepares the next |
| `VICTORY_WIDE_BACK=1` | **default in both scripts** (`-WideBack 0` / `-NoWideBack` off): snapshots and compares of shader-written ranges run on several threads |
| `-CardBuffersMinMB 1 -CardBuffersMB 1024` | **default in both scripts**: the card, not the CPU, looks for shader writes in buffers of 1 MiB or more (layer defaults 16 / 512). Faster (~220 vs ~400 ms a frame), at ~940 MB of VRAM |
| `VICTORY_INDIRECT_WINDOW=1` | **default in both scripts** (`-IndirectWindow 0` / `-NoIndirectWindow` off); off by default in the layer: the game draws its mesh records one per call from consecutive slots; this clamps up to 64 of them in one pass, instead of a compute pass between two waits before every draw |
| `-InPlace 1` / `VICTORY_INPLACE=1` | **default in `play.ps1` and `debug.ps1`** (`-InPlace 0` turns it off). Zero-copy (in the code upstream, off by default there): game memory outside buffers is opened as a host heap the card reads directly, instead of being copied (~6.4 GB of copies in a builder run). Locks up to `VICTORY_INPLACE_MB` (4096) of it into RAM. A `title memory in place` line every 10 s says what was placed and what was turned down |
| `-InPlace 2` | also the game's buffers (not the big ones in card memory). Turns overlap off (not compatible with late wait) |
| `-InPlaceProbe` / `VICTORY_INPLACE_PROBE=1` | asks the driver what it accepts in place; logs `in place probe` lines |
| `-GpuTiming` / `VICTORY_GPU_TIMING=1 VICTORY_D3D12_DRED=1` | times every command on the card and ranks them by pipeline (`the card's time by command`); runs slower |
| `-BarrierTest indirect` / `VICTORY_BARRIER_TEST` | timing only: leaves out GPU waits (`indirect`, `groups`, `both`) to measure what they cost; may glitch |
| `-SaveShaders <dir>` / `VICTORY_SHADER_SAVE` | saves each shader as given and as translated, by hash; the folder must be outside the repository |
| `-TextureIdleMS N` / `VICTORY_TEXTURE_IDLE_MS` | **1000 in both scripts**: how long an unused texture copy is kept on the card (default 5000, at least 250): shorter frees VRAM for textures still waiting |
| `-DisplayMode 1920x1080` / `VICTORY_DISPLAY_MODE` | **default in both scripts** (`-DisplayMode 3840x2160` for the layer's own): the TV size the console reports (layer default 3840x2160). If the game renders for the mode it is given, smaller means less GPU work and smaller render targets |
| `-Console series-s` | the game believes it runs on an Xbox Series S (`--console series-s`). **Does not work yet**: in that mode the game loads `amd_fidelityfx_upscaler_xbox.dll`, which the host policy refuses, and it stays on a black screen (11 draws a frame) |
| `-MeshCounts 1` / `VICTORY_MESH_COUNTS=1` (`why`: also print per shader) | experimental: a mesh shader declares the vertex and primitive counts the game asks for (its allocation request), where that can be done for all threads at once, instead of the declared maxima with the rest culled one by one; part of the shader cache key |
| `VICTORY_CARD_BUFFERS_MB=0` | keeps the game's large buffers out of card memory (more room for textures, likely slower) |

A failed DirectStorage write into physical pages now says why (an unknown page,
or a view that could not be mapped or committed).

### Findings so far (RTX 3070 Ti, 8 GB)

- Shader cache works: after the first run nearly every pipeline loads from the library.
- See-through textures: the card fills up (about 6.7 GB used of a ~7 GB budget, of
  which only ~2.2 GB are texture copies), after which textures picked by index wait.
- Ray tracing: with `-Builder -FirstLaneLocal` all 53 builder programs run (in
  quarantine), but frames go from ~0.45 s to ~4 s; lighting does not change yet
  (five compute pipelines are still refused by the driver, and some trace programs
  do not translate).
- With the builder on, the frame is mostly CPU bookkeeping (card ~12% busy):
  snapshots of every memory copy a raw-address shader might write (~1.9 s), copy-back
  (~1.5 s). Texture uploads are capped per frame, so at 4 s frames the queue grows and
  textures (e.g. clothing) go missing. Use `-Builder` only for testing.
- With `-NamedWrites` the builder's frame falls from ~4.1 s to ~0.64 s (snapshots ~1.9 s ->
  ~37 ms, copy-back ~1.5 s -> ~72 ms). The process then holds ~24 GB of private memory;
  on a PC with little free memory left, Windows pages heavily and the window may show
  as not responding. Raise the paging file and close other programs.
- `-InPlace 2` (no builder): CPU preparing ~190 -> ~98 ms, private memory ~24 -> ~20 GB,
  copies ~7.4 -> ~4.1 GB, but GPU time ~250 -> ~394 ms (card ~72% busy): only ~580 MB went
  in place; the game's page pool (6.1 GiB section made `SEC_RESERVE`) is turned down. The
  frame is now GPU-bound.
- `-InPlace 1` (now the default in both scripts): GPU ~287 ms, CPU preparing ~132 ms,
  ~2 fps, and visibly more textures and lighting than level 2. Commit left went from
  ~1.5 GB to ~25.8 GB once the paging file was raised.
- GPU timing: ~6,100 indirect commands a frame each get a bounding pass with two
  waits for every earlier shader write (~12,000 GPU-wide waits a frame); the single
  heaviest dispatches are `f22a76fcb967ee59` (~24 ms), `cfd83392ec9ae408` (~16 ms),
  `cb6adcc6da2613ff` (~10 ms) and `3592426e3e9142d8` (~7 ms).
- `-BarrierTest indirect` left GPU time unchanged (~289 ms): the waits are not the cost.
  The ~6,400 indirect commands themselves take ~147 ms (~23 us each), and the card is idle
  ~210 ms a frame waiting on the CPU, which `-Fast` (overlap) targets.
- Overlap (`VICTORY_RELAY=2`) with `-InPlace 1`: ~310-380 ms a frame (2.6-3.2 fps), card ~82%
  busy, GPU ~196 ms. Now the default.
- Of the four heaviest compute shaders, `f22a76fcb967ee59` (~3,900 instructions) and
  `3592426e3e9142d8` (~7,700) use `image_bvh64_intersect_ray` and raw-address loads: they are
  the game's ray-traversal programs walking the prebuilt structures, already running without
  the builder. `cfd83392ec9ae408` (250 instructions) and `cb6adcc6da2613ff` (~760) are plain
  compute; why the small one takes ~16 ms is not known yet.
- Defaults (`-InPlace 1` + overlap): 290-400 ms a frame (2.5-3.5 fps), GPU ~138 ms, card ~78%
  busy; the CPU still snapshots and compares ~350 MB of buffer copies a frame on one
  thread, which `VICTORY_WIDE_BACK=1` (now default) spreads over several.
- Card-side compares (`-CardBuffersMinMB 1 -CardBuffersMB 1024`, now default): CPU snapshots
  413 MB -> 26 MB a frame, copy-back ~314 -> ~168 ms, 290-410 ms a frame (2.4-3.5 fps).
- Indirect window: clamp passes ~6,400 -> ~1,900 a frame, **~220 ms a frame (4.5 fps)**, card
  ~82% busy. In the same run card memory was full (7,005 of 7,062 MB, card copies 941 MB) and
  textures stopped uploading (black shirt, missing items): the card-copy cap is back at 512 MB.
- With the cap at 512 MB the card was still full (~6.7 of ~7.0 GB): host textures ~5.3 GB, of
  which ~2.2 GB are copies of game textures and ~3.1 GB the game's own render targets, which
  cannot be let go. The shirt stayed missing, and frames went back to ~380-415 ms: the 1024 MB
  cap was also part of the 4.5 fps result. On 8 GB this is a trade of speed against textures.
- Rooms stay dark: indoor light comes from the ray-traced lighting, which needs the structure
  builder (still quarantined); only the prebuilt static structures are traversed today.
- `-TextureIdleMS 1000 -TexturePct 95 -CardBuffersMB 1024`: ~225-240 ms a frame (4.2-4.5 fps),
  nothing see-through, but card memory slightly over its budget (7,068 of 7,046 MB) and some
  items black. GPU ~153 ms, card ~82% busy: the frame is GPU-bound.
- `-DisplayMode 1920x1080` (now default with the above): **~196-208 ms a frame (4.8-5.1 fps)**,
  GPU ~131 ms, looks better. Host textures only fell ~5.3 -> ~5.2 GB, so the game's render
  targets barely shrank: it may follow the mode only in part.
- GPU timing at these defaults: ~182 ms of commands a frame, no single hot spot: ~6,300
  indirect mesh draws take ~126 ms (20-30 us each), the heaviest compute dispatch ~8 ms. The
  ray-traversal programs were not among the top in this scene.
- `-Console series-s`: black screen; the game asks for AMD's FidelityFX upscaler DLL, refused
  by the host policy. Series X stays the default.
- The heaviest mesh program (`db875f50a166bd91`, ~390 draws a frame) is small (224
  instructions); its translation declares 128 vertices and primitives per group and culls the
  unused ones, which `-MeshCounts` replaces with the game's own counts. PIX could not launch
  the layer ("unspecified error").
- `-MeshCounts why`: applied to all 313 mesh programs, none skipped, no errors; no measurable
  gain (~230-240 ms a frame, GPU ~153 ms, in a scene with ~6,000 draws against ~4,600 before).
  The game's mesh groups are probably mostly full. Left off by default. Card memory was over
  its budget in this run (7,177 of 6,885 MB), which costs speed too.
- `-DisplayMode 1280x720`: no change from 1080p (~205-250 ms a frame, GPU ~145 ms, host
  textures ~5.2 GB): below 1080p the game does not render smaller. 1080p stays the default.
- Of ~2,600-4,500 indirect mesh draws a frame, none could join the one before as recorded:
  there is always a title call between, and the state differs. What differs is logged next.
- Shaders saved with `VICTORY_SHADER_SAVE=<dir>` for study must stay outside
  the repository (docs/asset-policy.md).

## License

GPL-3.0-or-later (see `LICENSE`). Based on VIctory (Marvisak), victory-fork (fxceless) and ztrx
