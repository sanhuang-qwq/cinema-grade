#!/bin/sh
# Usage: sh smoke_test.sh [extra-image]. The test uses synthetic fixtures.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP_ROOT="${TMPDIR:-/tmp}"
OUT="$(mktemp -d "${TEMP_ROOT%/}/cinema-grade-smoke.XXXXXX")"
mkdir "$OUT/home"
export HOME="$OUT/home"
unset CINEMA_FRAME_BIN RAPIDRAW_BIN
echo "Test artifacts: $OUT"

echo "== 1. Doctor, automatic compilation, and version"
doctor_status=0
python3 "$HERE/batch_render.py" --doctor > "$OUT/doctor.txt" || doctor_status=$?
cat "$OUT/doctor.txt"
grep -q '^PASS macOS ' "$OUT/doctor.txt"
grep -q '^PASS swiftc:' "$OUT/doctor.txt"
grep -q '^PASS cinema_frame 1\.0\.0:' "$OUT/doctor.txt"
if grep -q '^PASS RapidRAW:' "$OUT/doctor.txt"; then
    test "$doctor_status" -eq 0
else
    grep -q '^WARN RapidRAW was not found' "$OUT/doctor.txt"
    test "$doctor_status" -eq 1
fi
CF="$(sed -n 's/^PASS cinema_frame 1\.0\.0: //p' "$OUT/doctor.txt")"
test -x "$CF"
test "$("$CF" --version)" = "cinema_frame 1.0.0"
test "$("$CF" version)" = "cinema_frame 1.0.0"

echo "== 2. Synthetic fixtures and image statistics"
cat > "$OUT/fixture.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
func make(_ name: String, _ w: Int, _ h: Int, _ bits: Int, _ type: String, orientation: Int? = nil) {
    let order = bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | order)!
    for row in 0..<2 {
        for col in 0..<2 {
            ctx.setFillColor(CGColor(colorSpace: cs,
                                     components: [0.18 + Double(col) * 0.5, 0.32,
                                                  0.2 + Double(row) * 0.5, 1])!)
            ctx.fill(CGRect(x: col * (w / 2), y: row * (h / 2), width: w / 2 + 1, height: h / 2 + 1))
        }
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
    let properties: [CFString: Any]? = orientation.map { value in
        [
            kCGImagePropertyOrientation: value,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFOrientation: value,
                kCGImagePropertyTIFFModel: "Cinema Grade Test Camera",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05",
                kCGImagePropertyExifPixelXDimension: w,
                kCGImagePropertyExifPixelYDimension: h,
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.4, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.2, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ]
    }
    CGImageDestinationAddImage(dst, ctx.makeImage()!, properties as CFDictionary?)
    precondition(CGImageDestinationFinalize(dst))
}
make("source.tiff", 2868, 1600, 16, "public.tiff", orientation: 1)
make("oriented.tiff", 320, 480, 16, "public.tiff", orientation: 6)
make("low.png", 4500, 320, 8, "public.png")
make("high.png", 320, 4501, 8, "public.png")
SWIFT
SWIFT_CACHE="$(dirname "$CF")/swift-modules"
swift -module-cache-path "$SWIFT_CACHE" "$OUT/fixture.swift" "$OUT"
SRC="$OUT/source.tiff"
"$CF" stats "$SRC" > "$OUT/stats.json"
"$CF" stats "$SRC" --dimensions-only > "$OUT/dimensions.json"
if [ "$#" -gt 0 ]; then "$CF" stats "$1"; fi

echo "== 3. Ruler, crop overlays, framing, and metadata"
cat > "$OUT/crops.json" <<'JSON'
[
  {"label":"横切转正", "mode":"h", "anchor_x":0.2, "anchor_y":0.8, "zoom":1.18, "rotate":12},
  {"label":"竖切", "mode":"v", "aspect":1.8, "anchor_x":0.72, "anchor_y":0.46, "zoom":1.2, "rotate":-3},
  {"label":"默认方向", "mode":"auto", "anchor_x":0.5, "anchor_y":0.5, "zoom":1, "rotate":0}
]
JSON
"$CF" ruler "$SRC" "$OUT/ruler.jpg" > "$OUT/ruler.json"
"$CF" preview-boxes "$SRC" "$OUT/boxes.jpg" --boxes "$OUT/crops.json" --max-long 900 > "$OUT/boxes.json"
"$CF" frame "$SRC" "$OUT/rotated.jpg" --mode h --anchor-x 0.2 --anchor-y 0.8 --zoom 1.18 --rotate 12 > "$OUT/rotated.json"
"$CF" frame "$SRC" "$OUT/vertical.jpg" --mode v --aspect 1.8 --anchor-x 0.72 --anchor-y 0.46 --zoom 1.2 --rotate -3 > "$OUT/vertical.json"
"$CF" frame "$SRC" "$OUT/default.png" > "$OUT/default.json"
"$CF" frame "$SRC" "$OUT/iphone.jpg" --canvas-aspect IPHONE > "$OUT/iphone.json"
"$CF" frame "$SRC" "$OUT/four-five.jpg" --canvas-aspect 4x5 > "$OUT/four-five.json"
"$CF" frame "$SRC" "$OUT/sixteen-nine.jpg" --canvas-aspect 16x9 > "$OUT/sixteen-nine.json"
"$CF" frame "$SRC" "$OUT/square.jpg" --canvas-aspect 1x1 > "$OUT/square.json"
"$CF" frame "$SRC" "$OUT/none.jpg" --canvas-aspect none > "$OUT/none.json"
"$CF" frame "$SRC" "$OUT/numeric.jpg" --canvas-aspect 1.25 > "$OUT/numeric.json"
"$CF" frame "$OUT/oriented.tiff" "$OUT/upright.tiff" > "$OUT/upright.json"
"$CF" frame "$OUT/oriented.tiff" "$OUT/stripped.png" --strip-metadata > "$OUT/stripped.json"
sips -g bitsPerSample -g profile "$OUT/default.png" > "$OUT/png-profile.txt"

echo "== 4. Grid and contact sheet"
set --
for row in 1 2 3; do
    for name in rotated.jpg vertical.jpg default.png; do set -- "$@" "$row=$OUT/$name"; done
done
"$CF" grid3x3 --out "$OUT/grid.jpg" --tile-long 300 --title "Pick a number · 選片" "$@" > "$OUT/grid.json"
"$CF" sheet --out "$OUT/sheet.jpg" --tile-long 300 --numbered "終稿=$OUT/rotated.jpg" "$OUT/vertical.jpg" > "$OUT/sheet.json"

cat > "$OUT/check-images.swift" <<'SWIFT'
import Foundation
import ImageIO

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func properties(_ name: String) -> [CFString: Any] {
    let url = dir.appendingPathComponent(name)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
}

let source = properties("oriented.tiff")
precondition(source[kCGImagePropertyOrientation] as? Int == 6)
for name in ["upright.tiff", "default.png", "rotated.jpg"] {
    let props = properties(name)
    let tiff = props[kCGImagePropertyTIFFDictionary] as! [CFString: Any]
    let exif = props[kCGImagePropertyExifDictionary] as! [CFString: Any]
    precondition(tiff[kCGImagePropertyTIFFModel] as? String == "Cinema Grade Test Camera", name)
    precondition(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:01:02 03:04:05", name)
    precondition(props[kCGImagePropertyGPSDictionary] != nil, name)
    precondition(props[kCGImagePropertyOrientation] as? Int == 1, name)
    precondition(tiff[kCGImagePropertyTIFFOrientation] as? Int == 1, name)
    let actualWidth = props[kCGImagePropertyPixelWidth] as! Int
    let actualHeight = props[kCGImagePropertyPixelHeight] as! Int
    let report = dir.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("json")
    let frame = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as! [String: Any]
    precondition(frame["final"] as? [Int] == [actualWidth, actualHeight], name)
    precondition((exif[kCGImagePropertyExifPixelXDimension] as? Int ?? actualWidth) == actualWidth, name)
    precondition((exif[kCGImagePropertyExifPixelYDimension] as? Int ?? actualHeight) == actualHeight, name)
}

for name in ["stripped.png", "ruler.jpg", "boxes.jpg", "grid.jpg", "sheet.jpg"] {
    let props = properties(name)
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    precondition(tiff?[kCGImagePropertyTIFFModel] == nil, name)
    precondition(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, name)
    precondition(props[kCGImagePropertyGPSDictionary] == nil, name)
}

for (name, width, height) in [("ruler.jpg", 1800, 1004), ("boxes.jpg", 900, 502),
                              ("grid.jpg", 932, 1066), ("sheet.jpg", 624, 346)] {
    let props = properties(name)
    precondition(props[kCGImagePropertyPixelWidth] as? Int == width, name)
    precondition(props[kCGImagePropertyPixelHeight] as? Int == height, name)
}
SWIFT
swift -module-cache-path "$SWIFT_CACHE" "$OUT/check-images.swift" "$OUT"

echo "== 5. Batch dry runs, guardrails, and composition previews"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$HERE/batch_render.py"
python3 - "$OUT" "$HERE" "$CF" <<'PY'
import contextlib
import importlib.util
import io
import json
import math
import os
import subprocess
import sys
from pathlib import Path

out = Path(sys.argv[1])
scripts = Path(sys.argv[2])
binary = Path(sys.argv[3])

def read(name):
    return json.loads((out / f"{name}.json").read_text())

stats, dimensions, ruler = map(read, ("stats", "dimensions", "ruler"))
assert (stats["width"], stats["height"]) == (dimensions["width"], dimensions["height"]) == (2868, 1600)
assert stats["p05"] <= stats["p50"] <= stats["p95"]
assert ruler["source"] == [2868, 1600] and ruler["size"] == [1800, 1004]
assert Path(ruler["dst"]) == out / "ruler.jpg"
grid, sheet = read("grid"), read("sheet")
assert (grid["tiles"], grid["cols"], grid["rows"]) == (9, 3, 3)
assert (sheet["tiles"], sheet["cols"], sheet["rows"]) == (2, 2, 1)

specs, boxes = read("crops"), read("boxes")
assert len(boxes) == 3 and [box["mode"] for box in boxes] == ["h", "v", "h"]
assert boxes[0]["anchorClamped"] is True
for index, (box, spec, name) in enumerate(zip(boxes, specs, ("rotated", "vertical", "default")), 1):
    frame = read(name)
    assert frame["noBlackCorners"] and frame["scale"] == 1
    assert box["number"] == index and box["label"] == spec["label"]
    for key in ("mode", "center", "cropSourcePixels", "anchorClamped"):
        assert box[key] == frame[key], (key, box, frame)
    cw, ch = frame["cropSourcePixels"]
    assert box["effectiveLongEdge"] == max(cw, ch)
    points = [(x * 2868, y * 1600) for x, y in box["vertices"]]
    assert len(points) == 4 and all(0 <= x <= 2868 and 0 <= y <= 1600 for x, y in points)
    (x0, y0), (x1, y1), (x2, y2), _ = points
    assert abs(math.hypot(x1 - x0, y1 - y0) - cw) < 1
    assert abs(math.hypot(x2 - x1, y2 - y1) - ch) < 1
    assert abs(math.degrees(math.atan2(y1 - y0, x1 - x0)) + spec["rotate"]) < 0.05
    for axis, source_edge in enumerate((2868, 1600)):
        center_from_vertices = sum(point[axis] for point in points) / (4 * source_edge)
        assert abs(center_from_vertices - box["center"][axis]) <= 0.0001

master = read("default")
assert master["final"] == master["crop"] == [2868, 1220] and master["bitsPerComponent"] == 16
assert read("none")["final"] == master["final"]
assert read("iphone")["final"] == [2868, 1320]
assert read("four-five")["final"] == read("numeric")["final"] == [2868, 2294]
assert read("sixteen-nine")["final"] == [2868, 1613]
assert read("square")["final"] == [2868, 2868]
assert read("upright")["source"] == [480, 320]
assert read("upright")["bitsPerComponent"] == read("stripped")["bitsPerComponent"] == 16
png = (out / "default.png").read_bytes()
assert png[24] == 16 and b"iCCP" in png
profile = (out / "png-profile.txt").read_text()
assert "bitsPerSample: 16" in profile and "Display P3" in profile, profile
assert all((out / name).stat().st_size > 0 for name in ("ruler.jpg", "boxes.jpg", "grid.jpg", "sheet.jpg"))

plan_path = out / "plan.json"
batch_out = out / "batch"
plan = {
    "out_dir": str(batch_out),
    "frame": {"mode": "v", "aspect": 1.9, "canvas_aspect": "IPHONE"},
    "export": {"keep_metadata": False},
    "final": {"keep_metadata": False},
    "variants": [{"id": variant} for variant in ("A", "B", "C")],
    "photos": [
        {"id": "mix", "src": "source.tiff", "frame": {"aspect": 2.35, "canvas_aspect": "4x5"},
         "crops": [*specs[:2], {k: v for k, v in specs[2].items() if k != "mode"}]},
        {"id": "low", "src": "low.png", "crops": [{"zoom": 1.35}, {"zoom": 1.36}]},
        {"id": "high", "src": "high.png", "crops": [{"zoom": 2.2}]},
        {"id": "over", "src": "high.png", "crops": [{"zoom": 2.21}]},
    ],
}
plan_path.write_text(json.dumps(plan))
cmd = [sys.executable, str(scripts / "batch_render.py"), str(plan_path)]

def batch(*args, ok=True):
    proc = subprocess.run(cmd + list(args), capture_output=True, text=True)
    body = proc.stdout + proc.stderr
    assert (proc.returncode == 0) == ok, body
    return body

dry = batch("--dry-run", "--only", "mix", "--pick", "mix=5")
assert "grid3x3" in dry and "--mode h --aspect 2.35" in dry and "--mode v --aspect 1.8" in dry
assert "--mode v --aspect 2.35" in dry and "Lossless final #5" in dry
assert "mix · Pick a number" in dry and "plan · Final Selection" in dry
assert "--format tiff --tiff-bit-depth 16" in dry
frame_commands = [line for line in dry.splitlines() if " --canvas-aspect " in line]
assert len(frame_commands) == 10
assert all("--canvas-aspect 4x5" in line and "--strip-metadata" in line for line in frame_commands)
assert "--keep-metadata" not in dry
assert not batch_out.exists()
plan["export"]["keep_metadata"] = True
plan["final"]["format"] = "jpg"
plan_path.write_text(json.dumps(plan))
dry = batch("--dry-run", "--only", "mix", "--pick", "mix=5")
frame_commands = [line for line in dry.splitlines() if " --canvas-aspect " in line]
assert len(frame_commands) == 10 and "--strip-metadata" in frame_commands[-1]
assert all("--strip-metadata" not in line for line in frame_commands[:-1])
assert "final/mix.jpg" in frame_commands[-1]
del plan["export"]
del plan["final"]
plan_path.write_text(json.dumps(plan))
assert "--canvas-aspect iphone" in batch("--dry-run", "--only", "high")
plan["frame"]["canvas_aspect"] = "invalid"
plan_path.write_text(json.dumps(plan))
assert "frame.canvas_aspect must be" in batch("--dry-run", ok=False)
del plan["frame"]["canvas_aspect"]
plan_path.write_text(json.dumps(plan))
assert "--canvas-aspect none" in batch("--dry-run", "--only", "high")
dry = batch("--dry-run", "--prep-rulers", "--preview-boxes", "--only", "high")
assert "Crop candidates:" in dry and "dimensions-only" in dry and not batch_out.exists()
cache_mtime = binary.stat().st_mtime_ns
batch("--prep-rulers", "--preview-boxes", "--only", "mix")
assert binary.stat().st_mtime_ns == cache_mtime
assert (batch_out / "rulers/mix_ruler.jpg").is_file()
assert (batch_out / "boxes/mix_boxes.jpg").is_file()
batch("--preview-boxes", "--only", "high", "--strict")
low = batch("--preview-boxes", "--only", "low", "--strict", ok=False)
assert "zoom=1.36" in low and "4500px" in low and "zoom=1.35" not in low
assert not (batch_out / "boxes/low_boxes.jpg").exists()
assert "zoom=1.36" in batch("--preview-boxes", "--only", "low")
assert (batch_out / "boxes/low_boxes.jpg").is_file()
over = batch("--preview-boxes", "--only", "over", "--strict", ok=False)
assert "zoom=2.21" in over and "4501px" in over and not (batch_out / "boxes/over_boxes.jpg").exists()
assert {p.name for p in batch_out.iterdir()} == {"rulers", "boxes"}

doctor_cmd = [sys.executable, str(scripts / "batch_render.py"), "--doctor"]
missing = subprocess.run(doctor_cmd, capture_output=True, text=True,
                         env=dict(os.environ, RAPIDRAW_BIN=str(out / "missing-rapidraw")))
assert missing.returncode == 1 and "FAIL RapidRAW:" in missing.stdout, missing.stdout
override = subprocess.run(doctor_cmd, capture_output=True, text=True,
                          env=dict(os.environ, RAPIDRAW_BIN="/usr/bin/true", CINEMA_FRAME_BIN=str(binary)))
assert override.returncode == 0 and "PASS RapidRAW: /usr/bin/true" in override.stdout, override.stdout
no_compiler = subprocess.run(doctor_cmd, capture_output=True, text=True,
                             env=dict(os.environ, PATH="", CINEMA_FRAME_BIN=str(binary),
                                      RAPIDRAW_BIN="/usr/bin/true"))
assert no_compiler.returncode == 1 and "xcode-select --install" in no_compiler.stdout, no_compiler.stdout
os.utime(binary, (0, 0))
batch("--prep-rulers", "--only", "mix")
assert binary.stat().st_mtime_ns >= (scripts / "cinema_frame.swift").stat().st_mtime_ns

# Test the lossless exporter directly so a preview export cannot write the look first.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("batch_render", scripts / "batch_render.py")
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)

class RapidRAWStub(render.Runner):
    def run(self, cmd, timeout=900):
        look = cmd[cmd.index("--adjustments") + 1]
        assert json.loads(look.read_text()) == {"toneMapper": "agx", "temperature": 12}
        cmd[cmd.index("--output") + 1].write_bytes(b"synthetic export")

stub = RapidRAWStub(False, binary, "RapidRAW")
master_plan = {"out_dir": out / "master", "final": render.DEFAULT_FINAL,
               "style": {"toneMapper": "agx"}}
photo = {"id": "test", "base": {"temperature": 12}, "use_sidecar": False}
variant = {"id": "A", "delta": {}}
source = out / "source.tiff"
master = render.export_lossless_master(stub, master_plan, photo, variant, source, True)
assert master.is_file()
(master_plan["out_dir"] / "looks/test_A.json").write_text("{}")
render.export_lossless_master(stub, master_plan, photo, variant, source, True)
photo["use_sidecar"] = True
try:
    render.export_lossless_master(stub, master_plan, photo, variant, source, True)
except render.PlanError as exc:
    assert "requires a .rrdata sidecar" in str(exc)
else:
    raise AssertionError("Lossless export accepted a missing sidecar")

render.STYLES_DIR = out / "invalid-styles"
render.STYLES_DIR.mkdir()
(render.STYLES_DIR / "invalid.json").write_text(json.dumps({
    "exposure": 1, "toneMapper": "basic", "grainAmount": 10,
    "tint": -5, "colorCalibration": {"shadowsTint": -5},
}))
messages = io.StringIO()
with contextlib.redirect_stdout(messages):
    assert render.lint_styles() == 1
for message in ("exposure keys", "toneMapper must be agx", "exceeds the limit of 9", "Green-cast guardrail"):
    assert message in messages.getvalue(), messages.getvalue()
PY
echo "== 6. Bundled style guardrails"
python3 "$HERE/batch_render.py" --lint-styles
echo "All smoke tests passed. Test artifacts: $OUT"
