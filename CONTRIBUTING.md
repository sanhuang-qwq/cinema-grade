# Contributing

Bug reports, fixes and new styles are welcome. The project is macOS only, so changes need to be tested on a Mac with RapidRAW ≥ 1.7.1 installed.

## Setup

```sh
git clone https://github.com/sanhuang-qwq/cinema-grade.git
cd cinema-grade/skills/cinema-grade
python3 scripts/batch_render.py --doctor
```

`--doctor` checks macOS, `swiftc`, the `cinema_frame` build and RapidRAW discovery. There are no third-party dependencies to install.

## Contributing a style

A style is one JSON file in `skills/cinema-grade/styles/`. It holds the look only; exposure belongs to each photo's `base` in `plan.json`.

1. **Grade in RapidRAW.** Open a representative photo, build the look, and save. RapidRAW writes a sidecar next to the photo, for example `IMG_0001.DNG.rrdata`.

2. **Extract the adjustments.**

   ```sh
   python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["adjustments"], indent=2))' \
     IMG_0001.DNG.rrdata > skills/cinema-grade/styles/my_style.json
   ```

3. **Reduce it to a pure style layer.**
   - Remove every exposure key: `exposure`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `dehaze`. Also remove geometry and local edits (`crop`, `rotation`, `masks`, `lutPath`) and any key left at its neutral value.
   - Keep `"toneMapper": "agx"`.
   - Keep white-balance offsets, `colorCalibration`, `hsl`, `colorGrading`, `pointCurves`, sharpening and grain. Key names and ranges are in [`references/rapidraw_schema.md`](skills/cinema-grade/references/rapidraw_schema.md).

4. **Add the two metadata keys at the top.**

   ```json
   {
     "_status": "experimental",
     "_description": "One or two sentences: highlight and shadow hues, sky and foliage treatment, contrast character, intended subjects.",
     "toneMapper": "agx"
   }
   ```

   New styles start as `experimental`. A style becomes `verified` once it has held up across a full real set; include the before/after images or the contact sheet in the pull request when you ask for promotion.

5. **Pass the guardrails.**

   | Rule | Requirement |
   | :--- | :--- |
   | No exposure keys | None of the seven keys listed in step 3 |
   | Anti-green | `tint` ≥ 0, `colorCalibration.shadowsTint` ≥ 0, green point curve at identity, no color wheel pushed toward green |
   | Grain | `grainAmount` between 6 and 9 |

   ```sh
   python3 scripts/batch_render.py --lint-styles
   ```

6. **Render it on at least three photos** with different light, using a `plan.json` based on [`references/plan.example.json`](skills/cinema-grade/references/plan.example.json), and check the contact sheet.

Name the file in lowercase snake case, describing the look rather than a place or a person (`night_tungsten_teal`, not `tokyo_trip`). Do not commit `.rrdata` sidecars or photos you do not have the right to publish.

## Changing the scripts

```sh
python3 scripts/batch_render.py --lint-styles
bash scripts/smoke_test.sh
```

`smoke_test.sh` compiles `cinema_frame`, generates synthetic fixtures and exercises framing, grids and plan validation. Both commands must pass; CI runs them on macOS for every pull request.

- `batch_render.py` stays dependency-free (Python 3.9+ standard library only).
- `cinema_frame.swift` stays a single file using system frameworks only. Do not commit the compiled binary.
- Source photos are read-only. No code path may write to, move or rename a file given in `photos[].src`.

## Pull requests

- One change per pull request, with a short description of what changed and how you tested it.
- Update `CHANGELOG.md` under an `Unreleased` heading, and `README.md` or `SKILL.md` if behaviour or flags changed.
- Keep `SKILL.md` agent-agnostic: no instructions that only work in one coding agent.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
