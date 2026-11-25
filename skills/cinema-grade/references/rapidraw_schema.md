# RapidRAW v1.7.1 parameter reference

Sources: the official v1.7.1 [CLI documentation](https://getrapidraw.com/docs/workflows/cli), sidecar examples published by the maintainer, and headless exports of iPhone ProRAW files. Keys marked **verified** were confirmed to take effect in a headless export. The rest only appear by name in official examples: test them on one photo before relying on them.

## Headless export

```sh
/Applications/RapidRAW.app/Contents/MacOS/RapidRAW export <source> --output <out.jpg> \
  --adjustments <look.json> --quality 95 --color-space srgb --on-conflict overwrite
```

- `export` and the source path must come first.
- There is no `--help`. Unknown options are silently ignored and the exit code is still 0, so judge success by whether the output file was regenerated.
- Exit codes: 0 success or skipped, 1 export error, 2 invalid argument value.
- Requires a Metal GPU. Inside a sandbox `MTLCreateSystemDefaultDevice()` returns nil, so the CLI must run non-sandboxed.
- The CLI has no resize option: every export is native resolution. Cropping and letterboxing belong to `cinema_frame`.
- When RAW decoding fails, RapidRAW may fall back to the embedded JPEG. The first time you process a new camera model, check that the output dimensions equal the full RAW dimensions.

| Option | Values | Default |
| :--- | :--- | :--- |
| `--output` | Directory or single file name | Required |
| `--adjustments` | Adjustment object JSON (below) | Reads the sidecar of the same name, otherwise applies defaults |
| `--format` | jpeg, png, tiff, webp, jxl, avif, cube | jpeg |
| `--quality` | 1–100 | 90 |
| `--color-space` | srgb, display-p3, adobe-rgb, prophoto-rgb, rec2020 | srgb |
| `--tiff-bit-depth` | 8, 16 | 16 |
| `--on-conflict` | keep-both, overwrite, overwrite-if-changed, skip | overwrite for a single file name |
| `--keep-metadata` | Keep camera metadata, including GPS | Off |
| `--hdr`, `--hdr-headroom` | Gain-map HDR, 1–4 EV | Off, 2 |

## Adjustment object

The `--adjustments` JSON is one flat object made of the keys below. Missing keys take neutral values.

### Base layer (per photo)

| Key | Range | Notes |
| :--- | :---: | :--- |
| `toneMapper` | `basic`, `agx` | Verified. Always `agx` for ProRAW; under `basic` HDR skies clip to white |
| `exposure` | EV | Verified. ProRAW usually needs +1.5 to +2.1 |
| `contrast` | −100–100 | Verified |
| `highlights` | −100–100 | Verified. High dynamic range scenes: −50 to −90 |
| `shadows` | −100–100 | Verified. Backlit scenes: +30 to +75 |
| `whites`, `blacks` | −100–100 | Verified |
| `clarity`, `dehaze` | −100–100 | Verified. Typically 4–8 each |
| `brightness` | −5–5 | |
| `structure` | −100–100 | |

### Style layer (shared by the whole set)

| Key | Range | Notes |
| :--- | :---: | :--- |
| `temperature`, `tint` | −100–100 | Verified. Relative to the as-shot white balance; positive `tint` is magenta, use +2 to +5 to counter green |
| `vibrance`, `saturation` | −100–100 | Verified |
| `hue` | −180–180 | |
| `colorCalibration.{red,green,blue}{Hue,Saturation}` | −100–100 | Verified. Primary calibration, the main tool for teal/orange separation |
| `colorCalibration.shadowsTint` | −100–100 | Verified. Use 0 to +3 to counter green |
| `hsl.<band>.{hue,saturation,luminance}` | −100–100 | Verified. Bands: `reds` `oranges` `yellows` `greens` `aquas` `blues` `purples` `magentas` |
| `colorGrading.{shadows,midtones,highlights,global}.{hue,saturation,luminance}` | hue 0–360, saturation 0–100, luminance −100–100 | Verified. OKLab color wheels |
| `colorGrading.balance`, `.blending` | −100–100, 0–100 | Verified. Neutral values 0 and 50 |
| `curveMode` | `point` | Verified |
| `pointCurves.{luma,red,green,blue}` | `[{x,y}]`, 0–255, at most 16 points per curve | Verified. Identity is `[{0,0},{255,255}]` |
| `parametricCurve.<channel>.{darks,shadows,lights,highlights,…}` | −100–100 | Not verified |
| `sharpness` | 0–100 | Verified |
| `grainAmount`, `grainSize`, `grainRoughness` | 0–100 | Verified |
| `vignetteAmount`, `glowAmount`, `halationAmount`, `flareAmount` | | Not verified |
| `lumaNoiseReduction`, `colorNoiseReduction` | | Not verified |

Crop, rotation, masks, LUTs and lens correction have keys in the example sidecars (`crop`, `rotation`, `masks`, `lutPath`, …). This workflow does not use them: all geometry goes through `cinema_frame`.

## Sidecar

Path: `<full photo file name>.rrdata`, next to the photo, for example `IMG_0001.DNG.rrdata`.

```json
{"version": 1, "rating": 0, "adjustments": { "...adjustment object..." }, "tags": null}
```

`export` without `--adjustments` reads the sidecar automatically, so after hand-tweaking and saving in the app, a plain re-export picks up the result. To extract the adjustment object from a sidecar and save it as a style:

```sh
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["adjustments"], indent=2))' IMG_0001.DNG.rrdata
```

The root structure is taken from the official example sidecars. The first time you use a sidecar written by this workflow, open it in the app and confirm the adjustments were read correctly.
