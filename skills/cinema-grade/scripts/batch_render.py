#!/usr/bin/env python3
"""Render a photo plan through RapidRAW and cinema_frame with Python 3.9+.

    python3 batch_render.py plan.json                 # Render the full plan
    python3 batch_render.py plan.json --dry-run       # Validate and print commands
    python3 batch_render.py plan.json --only 5443     # Limit rendering to a photo ID
    python3 batch_render.py plan.json --pick 5443=5   # Export a numbered selection
    python3 batch_render.py plan.json --prep-rulers   # Render source coordinate guides
    python3 batch_render.py plan.json --preview-boxes # Overlay candidate crops
    python3 batch_render.py --doctor                  # Check local tools
    python3 batch_render.py --lint-styles             # Check bundled styles

Adjustments merge in order: style, variant delta, then per-photo base.
RapidRAW reads working copies under out_dir/work and requires Metal access.
"""
import argparse
import copy
import hashlib
import json
import math
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
FRAME_SOURCE = SKILL_DIR / "scripts" / "cinema_frame.swift"
STYLES_DIR = SKILL_DIR / "styles"
RAPIDRAW_APP = Path("Applications/RapidRAW.app/Contents/MacOS/RapidRAW")
SWIFT_HINT = "Install Xcode Command Line Tools with xcode-select --install."
RAPIDRAW_HINT = "Install RapidRAW in Applications, add it to PATH, or set RAPIDRAW_BIN."
CANVAS_PRESETS = {"none", "iphone", "16x9", "4x5", "1x1"}

# Exposure keys belong in the per-photo base.
EXPOSURE_KEYS = {"exposure", "contrast", "highlights", "shadows", "whites", "blacks", "dehaze"}
BASE_KEYS = EXPOSURE_KEYS | {"brightness", "clarity", "structure", "toneMapper", "temperature", "tint"}
RAW_EXTS = {".dng", ".arw", ".cr2", ".cr3", ".nef", ".raf", ".rw2", ".orf"}

DEFAULT_EXPORT = {"quality": 95, "color_space": "display-p3", "keep_metadata": True, "write_sidecar": False}
DEFAULT_FINAL = {"format": "png", "bit_depth": 16, "color_space": "display-p3", "keep_metadata": True}
DEFAULT_FRAME = {"mode": "auto", "aspect": 2.35, "canvas_aspect": "none", "max_long": 0, "quality": 0.96}
DEFAULT_CROP = {"anchor_x": 0.5, "anchor_y": 0.5, "zoom": 1.0, "rotate": 0.0}
DEFAULT_GRID = {"tile_long": 1100, "sheet_tile_long": 900}


class PlanError(Exception):
    pass


def log(msg=""):
    print(msg, flush=True)


def warn(msg):
    print("  WARN " + msg, flush=True)


def executable(path):
    return path.is_file() and os.access(path, os.X_OK)


def find_rapidraw():
    override = os.environ.get("RAPIDRAW_BIN")
    if override:
        path = Path(override).expanduser().absolute()
        if not executable(path):
            raise PlanError(f"RAPIDRAW_BIN is not executable: {path}")
        return path
    on_path = shutil.which("RapidRAW") or shutil.which("rapidraw")
    if on_path:
        return Path(on_path).absolute()
    return next((path for path in (Path("/") / RAPIDRAW_APP, Path.home() / RAPIDRAW_APP)
                 if executable(path)), None)


def cinema_frame(dry_run=False):
    override = os.environ.get("CINEMA_FRAME_BIN")
    if override:
        path = Path(override).expanduser().absolute()
        if not dry_run and not executable(path):
            raise PlanError(f"CINEMA_FRAME_BIN is not executable: {path}")
        return path

    cache = Path.home() / ".cache" / "cinema-grade"
    binary = cache / f"cinema_frame-{platform.machine()}"
    if dry_run:
        return binary
    if executable(binary) and binary.stat().st_mtime_ns >= FRAME_SOURCE.stat().st_mtime_ns:
        return binary
    swiftc = shutil.which("swiftc")
    if not swiftc:
        raise PlanError(f"swiftc was not found. {SWIFT_HINT}")
    cache.mkdir(parents=True, exist_ok=True)
    # Publish only a complete binary, even if several runs compile at once.
    with tempfile.TemporaryDirectory(prefix="build-", dir=cache) as temp:
        candidate = Path(temp) / binary.name
        proc = subprocess.run(
            [swiftc, "-O", "-module-cache-path", str(cache / "swift-modules"),
             str(FRAME_SOURCE), "-o", str(candidate)],
            capture_output=True, text=True, timeout=180,
        )
        if proc.returncode:
            raise PlanError(f"Could not compile cinema_frame. {SWIFT_HINT}\n{proc.stderr.strip()}")
        candidate.replace(binary)
    return binary


def doctor():
    version = platform.mac_ver()[0]
    log(f"PASS macOS {version}" if version else "WARN macOS version unavailable. This tool requires macOS.")
    swiftc = shutil.which("swiftc")
    swift_ok = False
    if swiftc:
        try:
            Runner(False).run([swiftc, "--version"], timeout=30)
            log(f"PASS swiftc: {swiftc}")
            swift_ok = True
        except (PlanError, OSError, subprocess.TimeoutExpired) as exc:
            log(f"FAIL swiftc: {exc}\n  {SWIFT_HINT}")
    else:
        log(f"FAIL swiftc was not found. {SWIFT_HINT}")

    frame_ok = False
    try:
        binary = cinema_frame()
        version = Runner(False).run([binary, "--version"], timeout=30).strip()
        if not version.startswith("cinema_frame "):
            raise PlanError(f"Unexpected --version output: {version!r}")
        log(f"PASS {version}: {binary}")
        frame_ok = True
    except (PlanError, OSError, subprocess.TimeoutExpired) as exc:
        log(f"FAIL cinema_frame: {exc}")

    try:
        rapidraw = find_rapidraw()
    except PlanError as exc:
        log(f"FAIL RapidRAW: {exc}. {RAPIDRAW_HINT}")
        return 1
    if rapidraw:
        log(f"PASS RapidRAW: {rapidraw}")
    else:
        log(f"WARN RapidRAW was not found. {RAPIDRAW_HINT}")
    return 0 if swift_ok and frame_ok and rapidraw else 1


def deep_merge(base, over):
    """Merge dictionaries recursively without mutating either input. Replace other values."""
    out = copy.deepcopy(base)
    for key, val in over.items():
        if isinstance(val, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], val)
        else:
            out[key] = copy.deepcopy(val)
    return out


def strip_meta(adj):
    """Omit underscore-prefixed comment keys from RapidRAW adjustments."""
    return {k: v for k, v in adj.items() if not k.startswith("_")}


def canonical(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def resolve_path(raw, base_dir):
    p = Path(os.path.expanduser(str(raw)))
    return p if p.is_absolute() else (base_dir / p).resolve()


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise PlanError("File not found: %s" % path)
    except json.JSONDecodeError as exc:
        raise PlanError("Invalid JSON in %s: %s" % (path, exc))


def load_style(spec, plan_dir):
    """Load a style from an inline object, a bundled name, or a JSON path."""
    if spec is None:
        return {}, "(none)"
    if isinstance(spec, dict):
        return strip_meta(spec), "(inline)"
    named = STYLES_DIR / (str(spec) + ".json")
    path = named if named.is_file() else resolve_path(spec, plan_dir)
    data = load_json(path)
    if not isinstance(data, dict):
        raise PlanError("Style must be a JSON object: %s" % path)
    return strip_meta(data), str(path)


# ---------- guardrails ----------

def green_sources(adj):
    """Identify adjustments that introduce a green cast."""
    found = []
    if adj.get("tint", 0) < 0:
        found.append("tint=%s" % adj["tint"])
    shadows_tint = (adj.get("colorCalibration") or {}).get("shadowsTint", 0)
    if shadows_tint < 0:
        found.append("colorCalibration.shadowsTint=%s" % shadows_tint)
    green_curve = (adj.get("pointCurves") or {}).get("green") or []
    lift = max([pt.get("y", 0) - pt.get("x", 0) for pt in green_curve] or [0])
    if lift > 2:
        found.append("green curve lift +%s" % lift)
    grading = adj.get("colorGrading") or {}
    for zone in ("shadows", "midtones", "highlights", "global"):
        wheel = grading.get(zone) or {}
        if 75 <= wheel.get("hue", 0) <= 165 and wheel.get("saturation", 0) >= 8:
            found.append("colorGrading.%s hue=%s" % (zone, wheel["hue"]))
    return found


def lint_layers(style, variants, photo):
    msgs = []
    leaked = sorted(EXPOSURE_KEYS & set(style))
    if leaked:
        msgs.append("Move exposure keys %s from the style to the per-photo base" % leaked)
    for var in variants:
        leaked = sorted(EXPOSURE_KEYS & set(var.get("delta") or {}))
        if leaked:
            msgs.append("Variant %s mixes exposure keys into its delta: %s" % (var["id"], leaked))
    stray = sorted(set(photo.get("base") or {}) - BASE_KEYS)
    if stray:
        msgs.append("Move style keys %s from the per-photo base to the style or variant delta" % stray)
    return msgs


def lint_adjustments(adj, src=None):
    msgs = []
    if (src is None or src.suffix.lower() in RAW_EXTS) and adj.get("toneMapper") != "agx":
        msgs.append("toneMapper must be agx (got %r)" % adj.get("toneMapper"))
    grain = adj.get("grainAmount", 0)
    if grain > 9:
        msgs.append("grainAmount=%s exceeds the limit of 9" % grain)
    greens = green_sources(adj)
    if len(greens) >= 2:
        msgs.append("Green-cast guardrail: %d adjustments add green (%s)" % (len(greens), "; ".join(greens)))
    return msgs


def lint_styles():
    paths = sorted(STYLES_DIR.glob("*.json"))
    if not paths:
        log(f"FAIL No style JSON files found in {STYLES_DIR}")
        return 1
    failed = False
    for path in paths:
        try:
            style, _ = load_style(path, STYLES_DIR)
            grain = style.get("grainAmount", 0)
            if type(grain) not in (int, float) or not math.isfinite(grain):
                raise PlanError("grainAmount must be a finite number")
            problems = lint_layers(style, [], {}) + lint_adjustments(style)
        except (PlanError, OSError, TypeError, ValueError, OverflowError, AttributeError) as exc:
            problems = [str(exc)]
        if problems:
            failed = True
            for problem in problems:
                log(f"FAIL {path.name}: {problem}")
        else:
            log(f"PASS {path.name}")
    return int(failed)


def lint_zoom(runner, photo):
    crops = [crop for crop in photo["crops"] if crop["zoom"] > 1.35]
    if not crops:
        return []
    info = runner.run_json([runner.frame_bin, "stats", photo["src"], "--dimensions-only"])
    if runner.dry_run:
        log("    %s: Zoom limits depend on the source dimensions" % photo["id"])
        return []
    long_edge = max(info["width"], info["height"])
    limit = 1.35 if long_edge <= 4500 else 2.2
    return ["Crop %s has zoom=%g, above the %g limit for a %dpx long edge"
            % (crop["id"], crop["zoom"], limit, long_edge)
            for crop in crops if crop["zoom"] > limit]


# ---------- Plan parsing ----------

def normalize_canvas_aspect(value, context):
    if isinstance(value, str) and value.lower() in CANVAS_PRESETS:
        return value.lower()
    try:
        number = float(value)
        if not isinstance(value, bool) and math.isfinite(number) and number >= 0:
            return number
    except (TypeError, ValueError, OverflowError):
        pass
    raise PlanError(f"{context}.canvas_aspect must be none, iphone, 16x9, 4x5, 1x1, "
                    f"or a finite non-negative number. Got {value!r}")


def normalize_plan(plan, plan_path):
    plan_dir = plan_path.parent
    if not isinstance(plan, dict):
        raise PlanError("plan.json must contain an object at the top level")
    if not plan.get("out_dir"):
        raise PlanError("plan.json requires out_dir")
    photos = plan.get("photos")
    if not isinstance(photos, list) or not photos:
        raise PlanError("plan.json requires at least one photo")

    style, style_src = load_style(plan.get("style"), plan_dir)
    export = dict(DEFAULT_EXPORT, **(plan.get("export") or {}))
    final_cfg = dict(DEFAULT_FINAL, **(plan.get("final") or {}))
    frame = dict(DEFAULT_FRAME, **(plan.get("frame") or {}))
    frame["canvas_aspect"] = normalize_canvas_aspect(frame["canvas_aspect"], "frame")
    grid = dict(DEFAULT_GRID, **(plan.get("grid") or {}))
    deliver_dir = resolve_path(plan["deliver_dir"], plan_dir) if plan.get("deliver_dir") else None
    variants = plan.get("variants") or [{"id": "A", "label": "", "delta": {}}]

    seen = set()
    for var in variants:
        if not var.get("id"):
            raise PlanError("Each variant requires an id")
        if var["id"] in seen:
            raise PlanError("Duplicate variant ID: %s" % var["id"])
        seen.add(var["id"])
        var.setdefault("label", var["id"])
        var["delta"] = strip_meta(var.get("delta") or {})

    seen = set()
    norm_photos = []
    for photo in photos:
        pid = str(photo.get("id") or "")
        if not pid or "/" in pid:
            raise PlanError("Each photo requires an id without slashes")
        if pid in seen:
            raise PlanError("Duplicate photo ID: %s" % pid)
        seen.add(pid)
        if not photo.get("src"):
            raise PlanError("Photo %s requires src" % pid)
        src = resolve_path(photo["src"], plan_dir)
        if not src.is_file():
            raise PlanError("Source image for photo %s does not exist: %s" % (pid, src))
        crops = photo.get("crops") or [{"id": "c1", "label": "Centered"}]
        photo_frame = dict(frame, **(photo.get("frame") or {}))
        photo_frame["canvas_aspect"] = normalize_canvas_aspect(photo_frame["canvas_aspect"], f"Photo {pid} frame")
        norm_crops = []
        for idx, crop in enumerate(crops):
            merged = dict(DEFAULT_CROP, **crop)
            merged.setdefault("id", "c%d" % (idx + 1))
            merged.setdefault("label", merged["id"])
            for key in ("mode", "aspect"):
                merged.setdefault(key, photo_frame[key])
            context = "Photo %s, crop %s" % (pid, merged["id"])
            if merged["mode"] not in ("auto", "h", "v"):
                raise PlanError("%s: mode must be auto, h, or v" % context)
            for key in ("aspect", "anchor_x", "anchor_y", "zoom", "rotate"):
                try:
                    value = float(merged[key])
                except (TypeError, ValueError, OverflowError):
                    raise PlanError("%s: %s must be a finite number" % (context, key))
                if not math.isfinite(value):
                    raise PlanError("%s: %s must be a finite number" % (context, key))
                merged[key] = value
            if merged["aspect"] < 1 or merged["zoom"] < 1:
                raise PlanError("%s: aspect and zoom must be at least 1" % context)
            if abs(merged["rotate"]) > 45:
                raise PlanError("%s: rotate must be between -45 and 45 degrees" % context)
            norm_crops.append(merged)
        norm_photos.append({
            "id": pid,
            "src": src,
            "base": strip_meta(photo.get("base") or {}),
            "crops": norm_crops,
            "frame": photo_frame,
            "use_sidecar": bool(photo.get("use_sidecar")),
            "pick": photo.get("pick"),
        })

    return {
        "name": plan.get("name") or plan_path.stem,
        "out_dir": resolve_path(plan["out_dir"], plan_dir),
        "deliver_dir": deliver_dir,
        "style": style,
        "style_src": style_src,
        "export": export,
        "final": final_cfg,
        "frame": frame,
        "grid": grid,
        "variants": variants,
        "photos": norm_photos,
    }


def photo_variants(plan, photo):
    """Photos using a sidecar have one variant based on the working copy's .rrdata."""
    if photo["use_sidecar"]:
        return [{"id": "S", "label": "Manual sidecar", "delta": {}}]
    return plan["variants"]


def cell_list(plan, photo):
    """Number cells row by row, with a row per crop and a column per variant."""
    cells = []
    variants = photo_variants(plan, photo)
    for crop in photo["crops"]:
        for var in variants:
            cells.append({"n": len(cells) + 1, "crop": crop, "variant": var})
    return cells


# ---------- Rendering ----------

class Runner:
    def __init__(self, dry_run, frame_bin=None, rapidraw_bin=None):
        self.dry_run = dry_run
        self.frame_bin = frame_bin
        self.rapidraw_bin = rapidraw_bin

    def run(self, cmd, timeout=900):
        cmd = [str(c) for c in cmd]
        if self.dry_run:
            log("    $ " + shlex.join(cmd))
            return ""
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip()[-1500:]
            raise PlanError("Command failed (exit %d): %s\n%s" % (proc.returncode, shlex.join(cmd), tail))
        return proc.stdout

    def run_json(self, cmd):
        out = self.run(cmd)
        if self.dry_run:
            return {}
        for line in reversed(out.strip().splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    break
        raise PlanError("Expected JSON output from: %s" % shlex.join(cmd))


def ensure_work_copy(runner, src, work_dir):
    """Copy the source into work/ for subsequent steps."""
    dst = work_dir / src.name
    if src.resolve() == dst.resolve():
        return dst
    if runner.dry_run:
        log("    Copy source -> %s" % dst)
        return dst
    work_dir.mkdir(parents=True, exist_ok=True)
    stat = src.stat()
    if dst.is_file() and dst.stat().st_size == stat.st_size and int(dst.stat().st_mtime) == int(stat.st_mtime):
        return dst
    shutil.copy2(str(src), str(dst))
    return dst


def sidecar_fingerprint(runner, photo, work_src):
    sidecar = Path(str(work_src) + ".rrdata")
    if not sidecar.is_file():
        if runner.dry_run:
            return "sidecar:"
        raise PlanError(f"Photo {photo['id']} requires a .rrdata sidecar: {sidecar}")
    return "sidecar:" + hashlib.sha256(sidecar.read_bytes()).hexdigest()


def write_look(look, adj):
    body = json.dumps(adj, indent=2, ensure_ascii=False) + "\n"
    if not look.is_file() or look.read_text(encoding="utf-8", errors="replace") != body:
        look.parent.mkdir(parents=True, exist_ok=True)
        look.write_text(body, encoding="utf-8")


def export_graded(runner, plan, photo, variant, work_src, force):
    out_dir = plan["out_dir"]
    pid, vid = photo["id"], variant["id"]
    graded = out_dir / "graded" / ("%s_%s.jpg" % (pid, vid))
    cmd = [runner.rapidraw_bin, "export", work_src, "--output", graded, "--format", "jpeg",
           "--quality", int(plan["export"]["quality"]), "--color-space", plan["export"]["color_space"],
           "--on-conflict", "overwrite"]
    if plan["export"].get("keep_metadata"):
        cmd.append("--keep-metadata")

    adj = None
    look = out_dir / "looks" / ("%s_%s.json" % (pid, vid))
    if photo["use_sidecar"]:
        fingerprint = sidecar_fingerprint(runner, photo, work_src)
    else:
        adj = deep_merge(deep_merge(plan["style"], variant["delta"]), photo["base"])
        cmd += ["--adjustments", look]
        fingerprint = canonical(adj)
    fingerprint += "|" + canonical(plan["export"])

    stamp = out_dir / "looks" / ("%s_%s.stamp" % (pid, vid))
    fresh = (not force and graded.is_file() and graded.stat().st_size > 0 and stamp.is_file()
             and stamp.read_text(encoding="utf-8") == fingerprint
             and graded.stat().st_mtime >= work_src.stat().st_mtime)
    if fresh:
        log("  %s_%s adjustments unchanged. Using cached export." % (pid, vid))
        return graded, adj
    log("  %s_%s RapidRAW preview export" % (pid, vid))
    if not runner.dry_run:
        graded.parent.mkdir(parents=True, exist_ok=True)
        look.parent.mkdir(parents=True, exist_ok=True)
        if adj is not None:
            write_look(look, adj)
        if graded.exists():
            graded.unlink()          # Verify RapidRAW created a fresh output even if it exits successfully.
        if stamp.exists():
            stamp.unlink()
    runner.run(cmd)
    if not runner.dry_run:
        if not graded.is_file() or graded.stat().st_size == 0:
            raise PlanError("RapidRAW did not write %s. Make sure it can access Metal." % graded)
        stamp.write_text(fingerprint, encoding="utf-8")
    return graded, adj


def export_lossless_master(runner, plan, photo, variant, work_src, force):
    """Export a lossless TIFF for final framing."""
    out_dir = plan["out_dir"]
    pid, vid = photo["id"], variant["id"]
    fcfg = plan["final"]
    master = out_dir / "graded_16bit" / ("%s_%s.tiff" % (pid, vid))
    cmd = [runner.rapidraw_bin, "export", work_src, "--output", master, "--format", "tiff",
           "--tiff-bit-depth", int(fcfg.get("bit_depth", 16)),
           "--color-space", fcfg.get("color_space", "display-p3"),
           "--on-conflict", "overwrite"]
    if fcfg.get("keep_metadata", True):
        cmd.append("--keep-metadata")

    adj = None
    look = out_dir / "looks" / ("%s_%s.json" % (pid, vid))
    if photo["use_sidecar"]:
        fingerprint = sidecar_fingerprint(runner, photo, work_src)
    else:
        adj = deep_merge(deep_merge(plan["style"], variant["delta"]), photo["base"])
        cmd += ["--adjustments", look]
        fingerprint = canonical(adj)
    fingerprint += "|final:" + canonical(fcfg)

    stamp = out_dir / "looks" / ("%s_%s_16bit.stamp" % (pid, vid))
    fresh = (not force and master.is_file() and master.stat().st_size > 0 and stamp.is_file()
             and stamp.read_text(encoding="utf-8") == fingerprint
             and master.stat().st_mtime >= work_src.stat().st_mtime)
    if fresh:
        log("  %s_%s lossless master unchanged. Using cached export." % (pid, vid))
        return master
    log("  %s_%s RapidRAW lossless master export" % (pid, vid))
    if not runner.dry_run:
        master.parent.mkdir(parents=True, exist_ok=True)
        stamp.parent.mkdir(parents=True, exist_ok=True)
        if adj is not None:
            write_look(look, adj)
        if master.exists():
            master.unlink()
        if stamp.exists():
            stamp.unlink()
    runner.run(cmd)
    if not runner.dry_run:
        if not master.is_file() or master.stat().st_size == 0:
            raise PlanError("RapidRAW did not write the lossless master: %s" % master)
        stamp.write_text(fingerprint, encoding="utf-8")
    return master


def frame_cell(runner, photo, cell, graded, single, keep_metadata):
    crop, fr = cell["crop"], photo["frame"]
    cmd = [runner.frame_bin, "frame", graded, single,
           "--mode", crop["mode"], "--aspect", crop["aspect"], "--canvas-aspect", fr["canvas_aspect"],
           "--anchor-x", crop["anchor_x"], "--anchor-y", crop["anchor_y"],
           "--zoom", crop["zoom"], "--rotate", crop["rotate"],
           "--max-long", int(fr["max_long"]), "--quality", fr["quality"]]
    if not keep_metadata:
        cmd.append("--strip-metadata")
    info = runner.run_json(cmd)
    if info:
        if not info.get("noBlackCorners", True):
            raise PlanError("Black corners in %s: %s" % (single, info))
        if info.get("anchorClamped"):
            warn("%s #%d: Crop center clamped to %s" % (photo["id"], cell["n"], info.get("center")))
    return info


def prepare_previews(runner, photos, out_dir, rulers, boxes):
    for photo in photos:
        pid, src = photo["id"], photo["src"]
        if rulers:
            dst = out_dir / "rulers" / ("%s_ruler.jpg" % pid)
            runner.run([runner.frame_bin, "ruler", src, dst])
            log("  Ruler -> %s" % dst)
        if boxes:
            dst = out_dir / "boxes" / ("%s_boxes.jpg" % pid)
            cmd = [runner.frame_bin, "preview-boxes", src, dst, "--boxes"]
            keys = ("label", "mode", "aspect", "anchor_x", "anchor_y", "zoom", "rotate")
            specs = [{key: crop[key] for key in keys} for crop in photo["crops"]]
            if runner.dry_run:
                log("    Crop candidates: %s" % canonical(specs))
                runner.run(cmd + ["<temporary-crops.json>"])
            else:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8") as fh:
                    json.dump(specs, fh, ensure_ascii=False)
                    fh.flush()
                    info = json.loads(runner.run(cmd + [fh.name]))
                for box in info:
                    if box["anchorClamped"]:
                        warn("%s candidate %d: Crop center clamped to %s"
                             % (pid, box["number"], box["center"]))
            log("  Crop overlay -> %s" % dst)


def cell_label(cell):
    parts = [cell["crop"]["label"], cell["variant"]["label"]]
    # Use a full-width equals sign within labels to keep the label=path separator unambiguous.
    return " · ".join(p for p in parts if p).replace("=", "＝")


def write_sidecar(runner, plan, photo, work_src, adj, overwrite):
    """Write adjustments for fine-tuning in RapidRAW. Preserve manually edited sidecars by default."""
    sidecar = Path(str(work_src) + ".rrdata")
    ledger_path = plan["out_dir"] / "work" / ".sidecar_written.json"
    if runner.dry_run:
        log("    Write sidecar -> %s" % sidecar)
        return
    ledger = load_json(ledger_path) if ledger_path.is_file() else {}
    if sidecar.is_file() and not overwrite:
        current = hashlib.sha256(sidecar.read_bytes()).hexdigest()
        if ledger.get(sidecar.name) != current:
            warn("Preserving edited sidecar %s. Use --overwrite-sidecar to replace it." % sidecar.name)
            return
    body = json.dumps({"version": 1, "rating": 0, "adjustments": adj, "tags": None},
                      indent=2, ensure_ascii=False) + "\n"
    sidecar.write_text(body, encoding="utf-8")
    ledger[sidecar.name] = hashlib.sha256(body.encode("utf-8")).hexdigest()
    ledger_path.write_text(json.dumps(ledger, indent=2) + "\n", encoding="utf-8")
    log("  Wrote sidecar: %s" % sidecar)


def parse_picks(items):
    picks = {}
    for item in items or []:
        if "=" not in item:
            raise PlanError("--pick expects ID=N. Got %s" % item)
        pid, num = item.split("=", 1)
        try:
            picks[pid] = int(num)
        except ValueError:
            raise PlanError("--pick requires an integer selection: %s" % item)
    return picks


def main(argv=None):
    ap = argparse.ArgumentParser(description="Batch-render a cinema-grade photo plan.")
    ap.add_argument("plan", nargs="?", help="Path to plan.json")
    maintenance = ap.add_mutually_exclusive_group()
    maintenance.add_argument("--doctor", action="store_true", help="Check macOS and rendering tools")
    maintenance.add_argument("--lint-styles", action="store_true", help="Validate all bundled styles")
    ap.add_argument("--dry-run", action="store_true", help="Validate and print commands without running them or writing files")
    ap.add_argument("--only", action="append", default=[], metavar="ID", help="Process only this photo ID (repeatable)")
    ap.add_argument("--pick", action="append", default=[], metavar="ID=N", help="Export the numbered selection for a photo ID (repeatable)")
    ap.add_argument("--force", action="store_true", help="Refresh cached RapidRAW exports")
    ap.add_argument("--strict", action="store_true", help="Treat guardrail warnings as errors")
    ap.add_argument("--prep-rulers", action="store_true", help="Render only the source coordinate guides")
    ap.add_argument("--preview-boxes", action="store_true", help="Render only the crop overlays")
    ap.add_argument("--overwrite-sidecar", action="store_true", help="Replace manually edited .rrdata files")
    ap.add_argument("--deliver-dir", default=None, help="Copy final images to this directory")
    args = ap.parse_args(argv)
    if args.doctor:
        return doctor()
    if args.lint_styles:
        return lint_styles()
    if not args.plan:
        ap.error("a plan is required unless using --doctor or --lint-styles")

    plan_path = Path(os.path.expanduser(args.plan)).resolve()
    plan = normalize_plan(load_json(plan_path), plan_path)
    preview_only = args.prep_rulers or args.preview_boxes
    rapidraw = None
    if not preview_only:
        try:
            rapidraw = find_rapidraw()
            if rapidraw is None:
                raise PlanError(f"RapidRAW was not found. {RAPIDRAW_HINT}")
        except PlanError as exc:
            if not args.dry_run:
                raise
            warn(f"{exc} Dry run will print commands without executing them.")
            rapidraw = os.environ.get("RAPIDRAW_BIN") or "RapidRAW"
    runner = Runner(args.dry_run, cinema_frame(args.dry_run), rapidraw)
    out_dir = plan["out_dir"]
    work_dir = out_dir / "work"

    unknown = [pid for pid in args.only if pid not in {p["id"] for p in plan["photos"]}]
    if unknown:
        raise PlanError("Unknown photo IDs in --only: %s" % unknown)
    photos = [p for p in plan["photos"] if not args.only or p["id"] in args.only]

    log("Plan %s%s" % (plan["name"], " (dry-run)" if args.dry_run else ""))
    log("  Style: %s" % plan["style_src"])
    log("  Output: %s" % out_dir)
    log("  %d photos, %d color variants" % (len(photos), len(plan["variants"])))

    problems = []
    for photo in photos:
        guard_msgs = []
        if not preview_only or args.preview_boxes:
            guard_msgs.extend(lint_zoom(runner, photo))
        if not preview_only:
            if photo["frame"]["max_long"]:
                warn("%s: max_long=%s caps the crop resolution" % (photo["id"], photo["frame"]["max_long"]))
            guard_msgs.extend(lint_layers(plan["style"], plan["variants"], photo))
            if not photo["use_sidecar"]:
                for var in plan["variants"]:
                    adj = deep_merge(deep_merge(plan["style"], var["delta"]), photo["base"])
                    guard_msgs += ["%s: %s" % (var["id"], m) for m in lint_adjustments(adj, photo["src"])]
        for msg in guard_msgs:
            if args.strict:
                problems.append("%s: %s" % (photo["id"], msg))
            else:
                warn("%s: %s" % (photo["id"], msg))
    if problems:
        for msg in problems:
            warn(msg)
        if not args.dry_run or args.strict:
            raise PlanError("Preflight checks failed")

    if preview_only:
        prepare_previews(runner, photos, out_dir, args.prep_rulers, args.preview_boxes)
        return 0

    picks_path = out_dir / "picks.json"
    picks = load_json(picks_path) if picks_path.is_file() else {}
    for photo in plan["photos"]:
        if photo["pick"] is not None:
            picks[photo["id"]] = int(photo["pick"])
    picks.update(parse_picks(args.pick))
    for pid in picks:
        if pid not in {p["id"] for p in plan["photos"]}:
            raise PlanError("Unknown photo ID in selections: %s" % pid)

    stats = {}
    stats_path = out_dir / "stats.json"
    if stats_path.is_file():
        stats = load_json(stats_path)

    for photo in photos:
        pid = photo["id"]
        log("\n[%s] %s" % (pid, photo["src"]))
        work_src = ensure_work_copy(runner, photo["src"], work_dir)
        cells = cell_list(plan, photo)
        variants = photo_variants(plan, photo)
        graded, merged = {}, {}
        for var in variants:
            graded[var["id"]], merged[var["id"]] = export_graded(runner, plan, photo, var, work_src, args.force)
            if not runner.dry_run:
                st = runner.run_json([runner.frame_bin, "stats", graded[var["id"]]])
                stats["%s_%s" % (pid, var["id"])] = st
                log("    Luma p05/p50/p95 = %s/%s/%s  Highlight clip %.2f%%  Shadow clip %.2f%%  Green bias %+.1f  %sx%s" % (
                    st["p05"], st["p50"], st["p95"], st["highlightClip"] * 100, st["shadowClip"] * 100,
                    st["greenBias"], st["width"], st["height"]))

        singles = []
        for cell in cells:
            single = out_dir / "singles" / pid / ("%s_%d.jpg" % (pid, cell["n"]))
            frame_cell(runner, photo, cell, graded[cell["variant"]["id"]], single, plan["export"]["keep_metadata"])
            singles.append((cell, single))
        log("  %d framed previews -> %s" % (len(singles), out_dir / "singles" / pid))

        grid_path = out_dir / "grids" / ("%s_grid.jpg" % pid)
        items = ["%s=%s" % (cell_label(cell), single) for cell, single in singles]
        if len(photo["crops"]) == 3 and len(variants) == 3:
            runner.run([runner.frame_bin, "grid3x3", "--out", grid_path, "--title", "%s · Pick a number" % pid,
                        "--tile-long", int(plan["grid"]["tile_long"])] + items)
        else:
            runner.run([runner.frame_bin, "sheet", "--out", grid_path, "--numbered", "--cols", len(variants),
                        "--title", "%s · Pick a number" % pid,
                        "--tile-long", int(plan["grid"]["tile_long"])] + items)
        log("  Selection grid -> %s" % grid_path)

        pick = picks.get(pid)
        final_ext = str(plan["final"].get("format", "png")).lower().lstrip(".")
        if final_ext == "jpeg":
            final_ext = "jpg"
        if pick is not None:
            if not 1 <= pick <= len(cells):
                raise PlanError("%s: Selection %s is outside 1..%d" % (pid, pick, len(cells)))
            cell, _single = singles[pick - 1]
            final = out_dir / "final" / ("%s.%s" % (pid, final_ext))
            keep_metadata = plan["final"]["keep_metadata"]
            lossless = final_ext in ("png", "tif", "tiff")
            if lossless or (keep_metadata and not plan["export"]["keep_metadata"]):
                master = export_lossless_master(runner, plan, photo, cell["variant"], work_src, args.force)
                info = frame_cell(runner, photo, cell, master, final, keep_metadata)
                if runner.dry_run:
                    log("    %s #%d -> %s" % ("Lossless final" if lossless else "Final", pick, final))
                else:
                    log("  Final #%d (%s, %sbit %s) -> %s" % (
                        pick, cell_label(cell), info.get("bitsPerComponent", "?"),
                        info.get("colorSpace", "?"), final))
            elif not keep_metadata:
                frame_cell(runner, photo, cell, graded[cell["variant"]["id"]], final, keep_metadata)
                log("  Final #%d (%s) -> %s" % (pick, cell_label(cell), final))
            else:
                if runner.dry_run:
                    log("    Final #%d -> %s" % (pick, final))
                else:
                    final.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(str(_single), str(final))
                    log("  Final #%d (%s) -> %s" % (pick, cell_label(cell), final))
            deliver = resolve_path(args.deliver_dir, Path.cwd()) if args.deliver_dir else plan.get("deliver_dir")
            if deliver is not None:
                deliver_dst = deliver / final.name
                if runner.dry_run:
                    log("    Copy final -> %s" % deliver_dst)
                else:
                    deliver.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(str(final), str(deliver_dst))
                    log("  Delivered -> %s" % deliver_dst)
        if plan["export"].get("write_sidecar") and not photo["use_sidecar"]:
            chosen = cells[pick - 1]["variant"]["id"] if pick is not None else variants[0]["id"]
            write_sidecar(runner, plan, photo, work_src, merged[chosen], args.overwrite_sidecar)

    final_ext = str(plan["final"].get("format", "png")).lower().lstrip(".")
    if final_ext == "jpeg":
        final_ext = "jpg"
    finals = [(p["id"], out_dir / "final" / ("%s.%s" % (p["id"], final_ext))) for p in plan["photos"] if p["id"] in picks]
    if not runner.dry_run:
        finals = [(pid, path) for pid, path in finals if path.is_file()]
        out_dir.mkdir(parents=True, exist_ok=True)
        picks_path.write_text(json.dumps(picks, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        stats_path.write_text(json.dumps(stats, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if finals:
        sheet = out_dir / "contact_sheet.jpg"
        runner.run([runner.frame_bin, "sheet", "--out", sheet, "--title", "%s · Final Selection" % plan["name"],
                    "--tile-long", int(plan["grid"]["sheet_tile_long"])]
                   + ["%s #%s=%s" % (pid, picks[pid], path) for pid, path in finals])
        log("\nContact sheet (%d photos) -> %s" % (len(finals), sheet))
    else:
        log("\nNo selections yet. Use --pick ID=N to export a final.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (PlanError, OSError) as exc:
        print("Error: %s" % exc, file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired as exc:
        print("Error: Command timed out: %s" % exc, file=sys.stderr)
        sys.exit(1)
