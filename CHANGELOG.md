# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-24

Initial open-source release.

### Added
- `cinema-grade` agent skill: reference search, per-photo exposure normalization, shared style layer, ruler-based framing, 3×3 selection grid, final export.
- `batch_render.py`: plan-driven rendering through the RapidRAW CLI with layer merging (`style` ← `variants[].delta` ← `photos[].base`), export caching, `--dry-run`, `--only`, `--pick`, `--deliver-dir`, `--strict`.
- `--doctor` environment check (macOS, `swiftc`, helper compilation, RapidRAW discovery through `RAPIDRAW_BIN`, `PATH`, `/Applications`, `~/Applications`) and `--lint-styles` style validation.
- `cinema_frame` Swift helper, compiled on first run into `~/.cache/cinema-grade/`: `ruler`, `preview-boxes`, `frame`, `grid3x3`, `sheet`, `stats`.
- Borderless 2.35:1 framing by default, with canvas presets `none`, `iphone`, `16x9`, `4x5`, `1x1` or any float.
- 16-bit Display P3 PNG finals with optional EXIF preservation (`keep_metadata`).
- Guardrails: anti-green checks, `grainAmount` ≤ 9, zoom limits by source resolution, exposure keys kept out of style layers.
- Style library: two verified styles (`jp_warm_cream_cyan`, `us_west_cinema_matte`) and four experimental styles (`nordic_overcast_slate`, `noir_silver_mono`, `night_tungsten_teal`, `warm_editorial_portrait`).
- Claude Code plugin and marketplace manifests; installable with `npx skills add`.

[1.0.0]: https://github.com/sanhuang-qwq/cinema-grade/releases/tag/v1.0.0
