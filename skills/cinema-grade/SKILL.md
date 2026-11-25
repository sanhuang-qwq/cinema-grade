---
name: cinema-grade
description: >-
  Batch color grading and cinematic 2.35:1 framing for a set of photos on macOS, driven headlessly through RapidRAW. Normalizes exposure per photo, applies one shared style layer with anti-green and grain guardrails, designs crop candidates (x, y, zoom, rotate) by reading calibrated ruler overlays, renders a numbered 3x3 selection grid, and exports the picked frame as a 16-bit Display P3 PNG plus a contact sheet. Use when the user wants to grade or unify the look of a photo set (iPhone ProRAW/DNG, camera RAW, JPEG/HEIC), asks for a film, cinematic or Japanese-style look, wants widescreen crops or letterboxing, wants a pick-by-number grid, or mentions RapidRAW. 触发词：调色、修图、统一色调、电影感、日系、胶片感、宽幅裁切、2.35:1、加黑边、九宫格选片、ProRAW、RapidRAW。
license: MIT
compatibility: macOS only (Apple Silicon or Intel). Requires Xcode Command Line Tools (swiftc), Python 3.9+, and RapidRAW >= 1.7.1 with Metal GPU access, so commands must run non-sandboxed.
metadata:
  author: sanhuang-qwq
  version: "1.0.0"
---

# cinema-grade

Turn a set of photos into one consistent look and one consistent frame. The user makes two decisions: the style, and which numbered frame to keep. You do everything else.

## Hard rules
- **Source files are read-only.** Never move, rename, overwrite or edit the user's originals. `batch_render.py` copies each source into `<out_dir>/work/` and only touches the copy. Finals go to `<out_dir>/final/`, and to `--deliver-dir` if the user wants them somewhere else.
- **Run non-sandboxed.** The RapidRAW CLI needs a Metal GPU. Inside a sandbox it reports success and writes no file.
- **Fast previews, lossless finals.** Grids and preview singles are Display P3 JPEG. A picked frame is re-rendered through the full 16-bit pipeline (RapidRAW 16-bit Display P3 TIFF → `cinema_frame` crop → 16-bit Display P3 PNG) at native resolution (`max_long: 0`).
- **Never read or edit credential files.**

## Tools
Paths are relative to this skill directory.

| File | Purpose |
| :--- | :--- |
| `scripts/batch_render.py` | Reads `plan.json`, merges the three parameter layers, calls RapidRAW, then `cinema_frame` for singles, grids and the contact sheet |
| `scripts/cinema_frame.swift` | Framing helper: `ruler`, `preview-boxes`, `frame`, `grid3x3`, `sheet`, `stats`. Compiled automatically on first run into `~/.cache/cinema-grade/` |
| `styles/*.json` | Style library. Each file is one pure style layer with `_status` and `_description` |
| `references/rapidraw_schema.md` | RapidRAW parameter reference. Check key names here before writing parameters |
| `references/plan.example.json` | `plan.json` template |

Before the first run:
```sh
python3 scripts/batch_render.py --doctor        # macOS, swiftc, cinema_frame compile, RapidRAW discovery
python3 scripts/batch_render.py --lint-styles   # every styles/*.json against the guardrails
```
RapidRAW is looked up in `RAPIDRAW_BIN`, then `PATH`, `/Applications`, `~/Applications`. If `--doctor` fails, fix what it reports before continuing.

## Phase 0: references and style
- Ask for, or infer, the style direction. Strong stylization is fine; the grade does not have to stay close to the scene's literal colors.
- Check `styles/` first and read each `_description`. `verified` styles have passed full real shoots; `experimental` styles are color-theory starting points, so tell the user and expect to tune them.
- If nothing fits, use whatever web search or browser tool you have to collect 3–5 reference images. Read from them: the hue of highlights and shadows, the hue of sky and foliage, contrast and black-point lift, grain weight. Write a new style layer from that reading and save it in `styles/`.
- A style layer holds **style only**: white-balance offset, color calibration, HSL, color wheels, curves, sharpening, grain. No exposure keys (`exposure`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `dehaze`).

## Phase 1: per-photo exposure normalization
Each photo gets its own `base`. Goal: before any style is applied, brightness and dynamic range already match across the set.

| Input | `toneMapper` | `exposure` start | Notes |
| :--- | :---: | :---: | :--- |
| iPhone ProRAW (DNG) | `agx`, required | +1.5 to +2.1 | Under `basic`, HDR skies clip to white. Expect `highlights` −50 to −90 and `shadows` +30 to +75 on high-contrast scenes |
| Camera RAW (Sony, Fuji, Canon, Nikon) | `agx` | −0.3 to +0.8 | Much smaller shifts: start at 0 and correct by the stats. On a new camera model, confirm the export has the full RAW dimensions (RapidRAW can fall back to the embedded JPEG) |
| JPEG / HEIC | style default | 0, stay within ±0.3 | Already tone-mapped, 8-bit, little headroom. Keep `highlights` and `shadows` within about ±30. If the result looks flat or double tone-mapped, set `"toneMapper": "basic"` in that photo's `base` |

- Tune `exposure`, `highlights`, `shadows`, `contrast`, `dehaze` per photo, adding `whites`, `blacks`, `clarity` when needed. The wider the dynamic range, the harder you pull `highlights` down and lift `shadows`.
- Check with numbers, not by feel. `cinema_frame stats <image>` prints `p05/p50/p95`, `highlightClip`, `shadowClip`, `greenBias`; `batch_render.py` prints these after every export and saves them to `stats.json`. Bring each photo's `p50` close to the others and `highlightClip` near 0, then confirm by looking at the image.

## Phase 2: shared style and guardrails
- **One style for the whole set.** Do not adjust the style for a single photo. If one photo looks wrong, go back to Phase 1 and fix its `base`.
- **Anti-green guardrail.** Negative `tint`, negative `colorCalibration.shadowsTint`, a lifted green curve, and color wheels pushed toward green stack into a muddy image. Keep `tint` at +2 to +5, `shadowsTint` at 0 to +3, the green curve at identity, and reduce green only through HSL saturation.
- **Low grain.** `grainAmount` 6–9. More destroys native-resolution detail.
- `batch_render.py` checks these and warns; `--strict` turns warnings into errors.
- **Optional hand tweak.** `export.write_sidecar: true` writes a `.rrdata` sidecar next to the work copy. The user opens the copy in `<out_dir>/work/` with RapidRAW, adjusts and saves; then set `"use_sidecar": true` on that photo and re-run. A sidecar the user edited is never overwritten unless `--overwrite-sidecar` is passed.

## Phase 3: framing and selection
Default output is a pure 2.35:1 frame with no border (`frame.canvas_aspect: "none"`). Landscape (`h`) and portrait (`v`, 1:2.35) frames can be mixed in one set.

Canvas presets, valid in `plan.json` and `cinema_frame --canvas-aspect`. When the canvas is squarer than the crop, the frame is centered on a black canvas of that ratio:

| Preset | Ratio | Use |
| :--- | :---: | :--- |
| `none` (or `0`) | – | No border, default |
| `iphone` | 2.1727 (2868:1320) | Fills an iPhone screen with thin bars |
| `16x9` | 1.7778 | Video and desktop |
| `4x5` | 1.25 | Portrait social feed |
| `1x1` | 1.0 | Square |
| any float | long:short | Custom |

- **Choose orientation from the visual flow**, not from the source orientation: depth, cliffs and facades suit `v`; horizons and lateral spread suit `h`. Every crop can override `mode` and `aspect`.
- If a photo clearly suits another ratio (16:9, 4:3, 1:1), still deliver the 2.35 grid and mention it; the user decides.
- **Zoom guardrail.** Source long edge ≤ 4500 px (12 MP): `zoom` ≤ 1.35. Longer (48 MP): `zoom` ≤ 2.2.
- **Perspective first.** Fix converging verticals with `transformVertical` in the photo's adjustments before fine cropping.

Self-check in the background, then hand the user a clean grid:
1. **Measure on the ruler.** Run `--prep-rulers` to overlay a 10×10 coordinate grid (0.1–0.9), golden thirds lines and a center cross on each source. For every photo, measure the tilt of a real horizontal (horizon, waterline, mesa top) or vertical (pillar, trunk, facade) and compute `rotate`. Never default to `0.0` without measuring. Then read the subject's visual center to ±0.01 and list distractions at the edges and corners (bright corners, cut-off people, stray branches).
2. **Design three candidates with distinct intent**, not three evenly spaced cuts:
   - Row 1, wide: `zoom` 1.0–1.05. Keep the environment, level the horizon, put the subject on a thirds line.
   - Row 2, clean: `zoom` 1.12–1.35. Push in to remove edge distractions.
   - Row 3, bold: move the center of gravity, cut a minimal slice, or flip orientation.
3. **Reject bad boxes before rendering.** Write the candidates into `plan.json` and run `--preview-boxes`, which draws the three rotated boxes in three colors on the source. If a box clips a subject, leaves half an object, or is still tilted, fix the numbers first.

| Crop field | Meaning |
| :--- | :--- |
| `anchor_x`, `anchor_y` | Crop center in the source, 0–1, origin top-left. Out-of-range values are clamped and reported as `anchorClamped` |
| `zoom` | ≥ 1, extra push-in on top of the largest crop that fits |
| `rotate` | Degrees, clockwise. Horizon high on the right: positive. The largest inscribed rectangle without black corners is used |
| `mode`, `aspect` | Optional per-crop override (`auto`, `h`, `v`; default 2.35) |

The grid: **rows are the 3 crop candidates, columns are 3 subtle color variants** (`variants[].delta`: small moves in temperature, wheel saturation, single HSL bands), numbered 1–9 row by row.

Loop:
1. Write `plan.json` from `references/plan.example.json`. Run `--prep-rulers`, set the crops, run `--preview-boxes`.
2. `python3 scripts/batch_render.py plan.json` renders singles and `<out_dir>/grids/<id>_grid.jpg`. Look at each grid yourself, then show it to the user.
3. The user names a number: `python3 scripts/batch_render.py plan.json --pick <id>=<n> [--deliver-dir <dir>]`. The final lands in `<out_dir>/final/` as a 16-bit Display P3 PNG, and all finals are assembled into `contact_sheet.jpg`.
4. Review the contact sheet for the whole set: consistent tone, no photo brighter or greener than the rest, consistent framing. If it fails, return to Phase 1 or 3 and re-run only that photo with `--only <id>`. Unchanged grades are served from cache.

## plan.json
```json
{
  "name": "example-set",
  "out_dir": "./out/example-set",
  "style": "jp_warm_cream_cyan",
  "export": {"quality": 95, "color_space": "display-p3", "keep_metadata": true, "write_sidecar": false},
  "final": {"format": "png", "bit_depth": 16, "color_space": "display-p3", "keep_metadata": true},
  "frame": {"mode": "auto", "aspect": 2.35, "canvas_aspect": "none", "max_long": 0, "quality": 0.96},
  "variants": [
    {"id": "A", "label": "Baseline", "delta": {}},
    {"id": "B", "label": "Warmer", "delta": {"temperature": 6}},
    {"id": "C", "label": "Clearer cyan", "delta": {"hsl": {"aquas": {"saturation": 32}}}}
  ],
  "photos": [
    {"id": "0001", "src": "./samples/IMG_0001.DNG",
     "base": {"exposure": 1.48, "contrast": 18, "highlights": -65, "shadows": 28, "dehaze": 8},
     "crops": [
       {"label": "Wide", "anchor_x": 0.5, "anchor_y": 0.5, "zoom": 1.0, "rotate": 0},
       {"label": "Clean", "anchor_x": 0.56, "anchor_y": 0.48, "zoom": 1.18, "rotate": 1.2},
       {"label": "Bold", "anchor_x": 0.46, "anchor_y": 0.42, "zoom": 1.08, "rotate": 0.6}
     ]}
  ]
}
```
- Merge order: `style` ← `variants[].delta` ← `photos[].base`. Later layers win; nested objects merge key by key.
- `style` accepts a name in `styles/`, a JSON path, or an inline object. Relative paths resolve from the plan file.
- `final.keep_metadata: true` keeps EXIF in the final PNG (`DateTimeOriginal`, camera and lens, `Orientation` reset to 1). `false` strips it. Kept metadata can include GPS: ask before delivering files meant for publishing.
- If the grid is not exactly 3×3, a numbered contact sheet is used for selection instead.
- Flags: `--dry-run` validate and print commands only, `--only <id>`, `--force` ignore cache, `--strict` guardrail warnings become errors.

Output layout: `work/` source copies and sidecars, `rulers/`, `boxes/`, `looks/` the merged adjustments of every cell, `graded/` uncropped graded images, `singles/` native-resolution singles, `grids/`, `final/`, `contact_sheet.jpg`, `picks.json`, `stats.json`.

## cinema_frame reference
`--doctor` prints the compiled helper's path.
```sh
cinema_frame ruler <src> <dst> [--max-long 1800] [--quality 0.90]
cinema_frame preview-boxes <src> <dst> --boxes <json_file> [--max-long 1800] [--quality 0.90]
cinema_frame frame <src> <dst> --mode auto --aspect 2.35 --canvas-aspect none \
  --anchor-x 0.5 --anchor-y 0.5 --zoom 1.0 --rotate 0.0 --max-long 0 --quality 0.96
cinema_frame grid3x3 --out <dst> [--title text] <label=image> x9
cinema_frame sheet --out <dst> [--cols N] [--numbered] [--title text] <label=image> ...
cinema_frame stats <image>
```
`frame` prints one JSON line with `crop`, `final`, `center`, `anchorClamped`, `noBlackCorners`. If a rotated crop would leave the image, it fails without writing a file.

## Growing the style library
When a new style has held up across a full set, save its pure style layer to `styles/<name>.json` with `_status` and `_description`, and run `--lint-styles`. Promote `experimental` to `verified` only after a real shoot.
