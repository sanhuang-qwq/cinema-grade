// Crop images, build contact sheets, and measure image statistics.
// Build with swiftc -O cinema_frame.swift -o cinema_frame.
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let usage = """
cinema_frame — cinematic crops, contact sheets, and image statistics

  cinema_frame frame <src> <dst> [options]
      --mode auto|h|v       Crop orientation. Auto follows the source. [auto]
      --aspect 2.35         Crop ratio, long edge divided by short edge. [2.35]
      --canvas-aspect VALUE Canvas ratio or preset: none, iphone, 16x9, 4x5, 1x1. [none]
                           Zero or a ratio at least as wide as the crop adds no borders.
      --anchor-x 0.5        Horizontal crop center, from 0 (left) to 1 (right). [0.5]
      --anchor-y 0.5        Vertical crop center, from 0 (top) to 1 (bottom). [0.5]
                           Crop centers are clamped to keep the crop inside the source.
      --zoom 1.0            Zoom factor from the largest available crop. Minimum: 1. [1]
      --rotate 0.0          Clockwise rotation in degrees, up to 45 in either direction. [0]
      --max-long 0          Cap the crop's long edge in pixels. Zero keeps native size. [0]
      --quality 0.96        Lossy compression quality, from 0 to 1. [0.96]
      --strip-metadata      Omit source metadata.
      The output extension selects the format: .jpg/.jpeg/.png/.tif/.tiff/.heic.

  cinema_frame grid3x3 --out <dst> [--title TEXT] [--tile-long 1100] [--quality 0.92] <label=image> x9
      Number nine tiles in row order. Labels are optional.

  cinema_frame sheet --out <dst> [--cols N] [--title TEXT] [--tile-long 900] [--quality 0.92]
                     [--numbered] <label=image> ...
      Build a contact sheet from any number of images. Labels default to file names.

  cinema_frame ruler <src> <dst> [--max-long 1800] [--quality 0.90]
      Overlay coordinate ticks, rule-of-thirds guides, and a center mark. The origin is top left.

  cinema_frame preview-boxes <src> <dst> --boxes <json_file> [--max-long 1800] [--quality 0.90]
      Overlay crop candidates from a JSON array with label, mode, aspect, anchor_x, anchor_y, zoom, and rotate.

  cinema_frame stats <img> [--clip-hi 250] [--clip-lo 5] [--sample-long 2048] [--dimensions-only]
      Print dimensions, luma statistics, clipping rates, mean RGB, and green bias as JSON.

  cinema_frame --version

Exit codes: 0 success, 1 processing error, 2 invalid arguments.
"""

func fail(_ msg: String, code: Int32 = 1) -> Never {
    fputs("cinema_frame: \(msg)\n", stderr)
    exit(code)
}

// MARK: - Argument parsing

struct Parsed {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    func double(_ key: String, _ def: Double) -> Double {
        guard let raw = options[key] else { return def }
        guard let v = Double(raw), v.isFinite else { fail("--\(key) must be a finite number. Got \(raw)", code: 2) }
        return v
    }
    func int(_ key: String, _ def: Int) -> Int {
        guard let raw = options[key] else { return def }
        guard let v = Int(raw) else { fail("--\(key) must be an integer. Got \(raw)", code: 2) }
        return v
    }
    func string(_ key: String, _ def: String) -> String { options[key] ?? def }

    func canvasAspect() -> Double {
        let raw = string("canvas-aspect", "none")
        let presets: [String: Double] = [
            "none": 0, "iphone": 2868.0 / 1320, "16x9": 16.0 / 9, "4x5": 5.0 / 4, "1x1": 1,
        ]
        if let preset = presets[raw.lowercased()] { return preset }
        guard let value = Double(raw), value.isFinite, value >= 0 else {
            fail("--canvas-aspect must be a preset or a finite non-negative number. Got \(raw)", code: 2)
        }
        return value
    }
}

func parse(_ argv: [String], valueKeys: Set<String>, flagKeys: Set<String> = []) -> Parsed {
    var p = Parsed()
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            var key = String(a.dropFirst(2))
            var inlineValue: String? = nil
            if let eq = key.firstIndex(of: "=") {
                inlineValue = String(key[key.index(after: eq)...])
                key = String(key[..<eq])
            }
            if flagKeys.contains(key) {
                p.flags.insert(key)
            } else if valueKeys.contains(key) {
                if let v = inlineValue {
                    p.options[key] = v
                } else {
                    guard i + 1 < argv.count else { fail("--\(key) requires a value", code: 2) }
                    i += 1
                    p.options[key] = argv[i]
                }
            } else {
                fail("Unknown option --\(key)", code: 2)
            }
        } else {
            p.positional.append(a)
        }
        i += 1
    }
    return p
}

// MARK: - Image I/O

/// Load the image with its EXIF orientation baked into the pixels.
func readImage(_ path: String) -> (image: CGImage, properties: [CFString: Any]) {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("Could not read image: \(path)")
    }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if orientation == 1 { return (img, props) }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(img.width, img.height),
    ]
    guard let oriented = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        fail("Could not apply EXIF orientation: \(path)")
    }
    return (oriented, props)
}

func loadImage(_ path: String) -> CGImage { readImage(path).image }

func frameMetadata(_ source: [CFString: Any]) -> [CFString: Any] {
    let dimensionKeys: Set<CFString> = [
        kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
        kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
    ]
    // Let the encoder derive image structure from the rendered pixels.
    func removeDimensions(_ properties: [CFString: Any]) -> [CFString: Any] {
        properties.filter { !dimensionKeys.contains($0.key) }.mapValues { value in
            if let dictionary = value as? [CFString: Any] { return removeDimensions(dictionary) }
            return value
        }
    }
    var properties = removeDimensions(source)
    for key in [kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                kCGImagePropertyHasAlpha, kCGImagePropertyIsIndexed, kCGImagePropertyFileSize] {
        properties.removeValue(forKey: key)
    }
    properties[kCGImagePropertyOrientation] = 1
    var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    tiff[kCGImagePropertyTIFFOrientation] = 1
    properties[kCGImagePropertyTIFFDictionary] = tiff
    return properties
}

func saveImage(_ img: CGImage, to path: String, quality: Double, metadata: [CFString: Any] = [:]) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    } catch {
        fail("Could not create output directory: \(url.deletingLastPathComponent().path)")
    }
    let type: UTType
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": type = .jpeg
    case "png": type = .png
    case "tif", "tiff": type = .tiff
    case "heic": type = .heic
    default: fail("Unsupported output extension .\(url.pathExtension) (use jpg, png, tif, or heic)", code: 2)
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fail("Could not create output file: \(path)")
    }
    var options = metadata
    options[kCGImageDestinationLossyCompressionQuality] = min(1.0, max(0.01, quality))
    CGImageDestinationAddImage(dest, img, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("Could not write image: \(path)") }
}

func printJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { fail("Could not encode JSON") }
    print(s)
}

func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

/// Use the source RGB color space when possible to preserve wide gamut.
func workingColorSpace(_ img: CGImage) -> CGColorSpace {
    if let cs = img.colorSpace, cs.model == .rgb, cs.supportsOutput { return cs }
    return CGColorSpace(name: CGColorSpace.sRGB)!
}

func splitItem(_ item: String) -> (label: String?, path: String) {
    // Accept label=path or a plain path, including paths containing an equals sign.
    if FileManager.default.fileExists(atPath: item) { return (nil, item) }
    if let eq = item.firstIndex(of: "=") {
        return (String(item[..<eq]), String(item[item.index(after: eq)...]))
    }
    return (nil, item)
}

// MARK: - Crop geometry

struct CropGeometry {
    let vertical: Bool
    let width: Double
    let height: Double
    let centerX: Double
    let centerY: Double
    let anchorClamped: Bool
    let sourceToCrop: CGAffineTransform

    var sourcePixels: [Int] { [Int(width), Int(height)] }
    var effectiveLongEdge: Int { Int(max(width, height)) }

    func normalizedCenter(sourceWidth: Double, sourceHeight: Double) -> [Double] {
        [r4(centerX / sourceWidth), r4(centerY / sourceHeight)]
    }

    // Map crop corners to source coordinates, with the origin at bottom left.
    var sourceVertices: [CGPoint] {
        let cropToSource = sourceToCrop.inverted()
        return [CGPoint(x: 0, y: height), CGPoint(x: width, y: height),
                CGPoint(x: width, y: 0), CGPoint(x: 0, y: 0)].map { $0.applying(cropToSource) }
    }
}

func cropGeometry(width W: Double, height H: Double, mode: String, aspect: Double,
                  anchorX: Double, anchorY: Double, zoom: Double, rotate: Double) -> CropGeometry {
    guard ["auto", "h", "v"].contains(mode) else { fail("--mode must be auto, h, or v", code: 2) }
    guard aspect >= 1 else { fail("--aspect must be at least 1", code: 2) }
    guard zoom >= 1 else { fail("--zoom must be at least 1", code: 2) }
    guard abs(rotate) <= 45 else { fail("--rotate must be between -45 and 45 degrees", code: 2) }
    let vertical = mode == "v" || (mode == "auto" && H > W)
    let a = vertical ? 1.0 / aspect : aspect            // Crop width divided by height.

    // Tilt the crop against the rotation and keep its bounding box inside the source.
    let theta = rotate * .pi / 180
    let c = abs(cos(theta)), s = abs(sin(theta))
    // Leave two pixels on each edge during rotation for interpolation.
    let margin = rotate == 0 ? 0.0 : 2.0
    let availW = W - 2 * margin, availH = H - 2 * margin
    var cw = min(availW / (c + s / a), availH / (s + c / a)) / zoom
    var ch = cw / a
    if rotate == 0 {
        cw = min(W, cw.rounded()); ch = min(H, ch.rounded())
    } else {
        cw = floor(cw); ch = floor(ch)
    }
    guard cw >= 16, ch >= 16 else { fail("Crop is too small. Check --zoom and --rotate.") }

    let hx = (cw * c + ch * s) / 2 + margin
    let hy = (cw * s + ch * c) / 2 + margin
    let wantX = W * anchorX, wantY = H * anchorY
    var cx = min(max(wantX, hx), W - hx)
    var cy = min(max(wantY, hy), H - hy)
    if rotate == 0 {
        // Align an unrotated crop to whole pixels to preserve the source samples.
        cx = min(max((cx - cw / 2).rounded(), 0), W - cw) + cw / 2
        cy = min(max((cy - ch / 2).rounded(), 0), H - ch) + ch / 2
    }
    let clamped = abs(cx - wantX) > 1.0 || abs(cy - wantY) > 1.0

    // Core Graphics uses an upward y-axis, so a negative angle rotates pixels clockwise.
    let sourceToCrop = CGAffineTransform(translationX: cw / 2, y: ch / 2)
        .rotated(by: -theta).translatedBy(x: -cx, y: -(H - cy))
    return CropGeometry(vertical: vertical, width: cw, height: ch, centerX: cx, centerY: cy,
                        anchorClamped: clamped, sourceToCrop: sourceToCrop)
}

// MARK: - frame

func runFrame(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["mode", "aspect", "canvas-aspect", "anchor-x", "anchor-y",
                                    "zoom", "rotate", "max-long", "quality"], flagKeys: ["strip-metadata"])
    guard p.positional.count == 2 else { fail("frame requires <src> <dst>", code: 2) }
    let srcPath = p.positional[0], dstPath = p.positional[1]
    let mode = p.string("mode", "auto")
    let aspect = p.double("aspect", 2.35)
    let canvasAspect = p.canvasAspect()
    let anchorX = p.double("anchor-x", 0.5), anchorY = p.double("anchor-y", 0.5)
    let zoom = p.double("zoom", 1.0)
    let rotate = p.double("rotate", 0.0)
    let maxLong = p.int("max-long", 0)
    let quality = p.double("quality", 0.96)
    guard maxLong >= 0 else { fail("--max-long must be non-negative", code: 2) }

    let (img, properties) = readImage(srcPath)
    let W = Double(img.width), H = Double(img.height)
    let geometry = cropGeometry(width: W, height: H, mode: mode, aspect: aspect,
                                anchorX: anchorX, anchorY: anchorY, zoom: zoom, rotate: rotate)
    let cw = geometry.width, ch = geometry.height, vertical = geometry.vertical
    let scale = maxLong > 0 ? min(1.0, Double(maxLong) / max(cw, ch)) : 1.0
    let outW = max(1, Int((cw * scale).rounded())), outH = max(1, Int((ch * scale).rounded()))

    // Render the crop and any rotation at native resolution on a transparent canvas.
    // Keep 16-bit color throughout for high-bit-depth sources exported as PNG or TIFF.
    let nativeW = Int(cw), nativeH = Int(ch)
    let cs = workingColorSpace(img)
    let dstExt = URL(fileURLWithPath: dstPath).pathExtension.lowercased()
    let use16Bit = img.bitsPerComponent > 8 && (dstExt == "png" || dstExt == "tif" || dstExt == "tiff")
    let bpc = use16Bit ? 16 : 8
    let cropBitmapInfo = use16Bit
        ? (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let cropCtx = CGContext(data: nil, width: nativeW, height: nativeH, bitsPerComponent: bpc,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: cropBitmapInfo) else {
        fail("Could not create crop canvas \(nativeW)x\(nativeH) (\(bpc)bit)")
    }
    cropCtx.interpolationQuality = .high
    cropCtx.concatenate(geometry.sourceToCrop)
    cropCtx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

    // Check every edge pixel for low alpha, which indicates uncovered canvas.
    var edgeAlphaMin = use16Bit ? 65535 : 255
    if let data = cropCtx.data {
        let bpr = cropCtx.bytesPerRow
        if use16Bit {
            let stride = bpr / 2
            let px = data.bindMemory(to: UInt16.self, capacity: stride * nativeH)
            for x in 0..<nativeW {
                edgeAlphaMin = min(edgeAlphaMin, Int(px[x * 4 + 3]), Int(px[(nativeH - 1) * stride + x * 4 + 3]))
            }
            for y in 0..<nativeH {
                edgeAlphaMin = min(edgeAlphaMin, Int(px[y * stride + 3]), Int(px[y * stride + (nativeW - 1) * 4 + 3]))
            }
        } else {
            let px = data.bindMemory(to: UInt8.self, capacity: bpr * nativeH)
            for x in 0..<nativeW {
                edgeAlphaMin = min(edgeAlphaMin, Int(px[x * 4 + 3]), Int(px[(nativeH - 1) * bpr + x * 4 + 3]))
            }
            for y in 0..<nativeH {
                edgeAlphaMin = min(edgeAlphaMin, Int(px[y * bpr + 3]), Int(px[y * bpr + (nativeW - 1) * 4 + 3]))
            }
        }
    }
    let noBlackCorners = use16Bit ? (edgeAlphaMin >= 64000) : (edgeAlphaMin >= 250)
    if !noBlackCorners { fail("Crop extends beyond the source (edgeAlphaMin=\(edgeAlphaMin)). Output was not written.") }
    guard let cropped = cropCtx.makeImage() else { fail("Could not render crop") }

    // Apply --max-long, then center the crop on the output canvas.
    var canvasW = outW, canvasH = outH
    if canvasAspect > 0 && canvasAspect < aspect {
        let longEdge = vertical ? outH : outW
        guard let paddedEdge = Int(exactly: (Double(longEdge) / canvasAspect).rounded()) else {
            fail("--canvas-aspect produces a canvas that is too large", code: 2)
        }
        if vertical { canvasW = max(outW, paddedEdge) }
        else { canvasH = max(outH, paddedEdge) }
    }
    let outBitmapInfo = use16Bit
        ? (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: bpc,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: outBitmapInfo) else {
        fail("Could not create output canvas \(canvasW)x\(canvasH) (\(bpc)bit)")
    }
    let black = CGColor(colorSpace: cs, components: [0, 0, 0, 1]) ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.setFillColor(black)
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
    ctx.interpolationQuality = scale < 1 ? .high : .none
    ctx.draw(cropped, in: CGRect(x: (canvasW - outW) / 2, y: (canvasH - outH) / 2, width: outW, height: outH))
    guard let out = ctx.makeImage() else { fail("Could not render output") }
    let metadata = p.flags.contains("strip-metadata") ? [:] : frameMetadata(properties)
    saveImage(out, to: dstPath, quality: quality, metadata: metadata)

    printJSON([
        "dst": dstPath,
        "mode": vertical ? "v" : "h",
        "source": [img.width, img.height],
        "crop": [outW, outH],
        "final": [canvasW, canvasH],
        "cropSourcePixels": geometry.sourcePixels,
        "center": geometry.normalizedCenter(sourceWidth: W, sourceHeight: H),
        "anchorClamped": geometry.anchorClamped,
        "zoom": zoom,
        "rotate": rotate,
        "scale": r4(scale),
        "bitsPerComponent": out.bitsPerComponent,
        "colorSpace": (out.colorSpace?.name as String?) ?? "unknown",
        "edgeAlphaMin": edgeAlphaMin,
        "noBlackCorners": noBlackCorners,
    ])
}

// MARK: - Composition previews

struct PreviewCanvas {
    let context: CGContext
    let width: Double
    let height: Double
    let sourceWidth: Double
    let sourceHeight: Double
    let fontSize: Double

    init(image: CGImage, maxLong: Int) {
        sourceWidth = Double(image.width)
        sourceHeight = Double(image.height)
        let scale = maxLong > 0 ? min(1, Double(maxLong) / max(sourceWidth, sourceHeight)) : 1
        width = max(1, (sourceWidth * scale).rounded())
        height = max(1, (sourceHeight * scale).rounded())
        fontSize = max(8, min(28, min(width, height) * 0.022))
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: workingColorSpace(image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fail("Could not create composition preview canvas")
        }
        context = ctx
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func stroke(_ path: CGPath, color: CGColor, width: Double, outline: Double = 0) {
        if outline > 0 {
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.85))
            context.setLineWidth(width + outline * 2)
            context.addPath(path)
            context.strokePath()
        }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }

    func label(_ value: String, at point: CGPoint, color: NSColor,
               avoiding occupied: [CGRect] = []) -> CGRect {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        let string = value as NSString
        let pad = fontSize * 0.2
        let textSize = string.size(withAttributes: attrs)
        let w = min(width, ceil(textSize.width + pad * 2))
        let h = min(height, ceil(textSize.height + pad))
        func bounds(_ dy: Double) -> CGRect {
            CGRect(x: max(0, min(point.x, width - w)),
                   y: max(0, min(point.y - h + dy, height - h)), width: w, height: h)
        }
        let offsets = [0.0] + (1...max(1, occupied.count)).flatMap { [Double($0) * h, -Double($0) * h] }
        let rect = offsets.lazy.map(bounds).first { candidate in
            !occupied.contains { $0.intersects(candidate) }
        } ?? bounds(0)
        context.setFillColor(CGColor(gray: 0, alpha: 0.9))
        context.fill(rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(in: rect.insetBy(dx: pad, dy: 0), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return rect
    }

    func save(to path: String, quality: Double) {
        guard let out = context.makeImage() else { fail("Could not render composition preview") }
        saveImage(out, to: path, quality: quality)
    }
}

func runRuler(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["max-long", "quality"])
    guard p.positional.count == 2 else { fail("ruler requires <src> <dst>", code: 2) }
    let maxLong = p.int("max-long", 1800), quality = p.double("quality", 0.90)
    guard maxLong >= 0 else { fail("--max-long must be non-negative", code: 2) }
    let img = loadImage(p.positional[0]), dst = p.positional[1]
    let canvas = PreviewCanvas(image: img, maxLong: maxLong)
    let w = canvas.width, h = canvas.height
    let line = max(1, canvas.fontSize * 0.06)
    let grid = CGMutablePath()
    func gridLines(_ fraction: Double, in path: CGMutablePath) {
        let x = w * fraction, y = h * (1 - fraction)
        path.move(to: CGPoint(x: x, y: h))
        path.addLine(to: CGPoint(x: x, y: 0))
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: w, y: y))
    }
    for i in 1...9 { gridLines(Double(i) / 10, in: grid) }
    canvas.stroke(grid, color: CGColor(gray: 1, alpha: 0.55), width: line, outline: line * 0.5)
    let ticks = CGMutablePath()
    for i in 1..<100 {
        let x = w * Double(i) / 100, y = h * Double(100 - i) / 100
        let length = canvas.fontSize * (i.isMultiple(of: 5) ? 0.42 : 0.22)
        ticks.move(to: CGPoint(x: x, y: h))
        ticks.addLine(to: CGPoint(x: x, y: h - length))
        ticks.move(to: CGPoint(x: 0, y: y))
        ticks.addLine(to: CGPoint(x: length, y: y))
    }
    canvas.stroke(ticks, color: CGColor(gray: 1, alpha: 0.8), width: line, outline: line * 0.5)
    let guides = CGMutablePath()
    gridLines(1.0 / 3, in: guides)
    gridLines(2.0 / 3, in: guides)
    let center = CGPoint(x: w / 2, y: h / 2), arm = canvas.fontSize * 0.8
    guides.move(to: CGPoint(x: center.x - arm, y: center.y))
    guides.addLine(to: CGPoint(x: center.x + arm, y: center.y))
    guides.move(to: CGPoint(x: center.x, y: center.y - arm))
    guides.addLine(to: CGPoint(x: center.x, y: center.y + arm))
    let gold = NSColor(srgbRed: 1, green: 0.75, blue: 0.27, alpha: 0.96)
    canvas.stroke(guides, color: gold.cgColor, width: line * 1.8, outline: line * 0.6)
    for i in 1...9 {
        let fraction = Double(i) / 10
        _ = canvas.label("0.\(i)", at: CGPoint(x: w * fraction + line, y: h - canvas.fontSize * 0.45),
                         color: .white)
        _ = canvas.label("0.\(i)", at: CGPoint(x: canvas.fontSize * 0.45, y: h * (1 - fraction) - line),
                         color: .white)
    }
    canvas.save(to: dst, quality: quality)
    printJSON(["dst": dst, "source": [img.width, img.height], "width": img.width, "height": img.height,
               "size": [Int(w), Int(h)]])
}

struct PreviewBox: Decodable {
    let label: String
    let mode: String
    let aspect: Double?
    let anchor_x: Double
    let anchor_y: Double
    let zoom: Double
    let rotate: Double
}

func runPreviewBoxes(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["boxes", "max-long", "quality"])
    guard p.positional.count == 2, let boxesPath = p.options["boxes"] else {
        fail("preview-boxes requires <src> <dst> --boxes <json_file>", code: 2)
    }
    let maxLong = p.int("max-long", 1800), quality = p.double("quality", 0.90)
    guard maxLong >= 0 else { fail("--max-long must be non-negative", code: 2) }
    let boxes: [PreviewBox]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: boxesPath))
        boxes = try JSONDecoder().decode([PreviewBox].self, from: data)
    } catch {
        fail("Could not read crop candidates from \(boxesPath): \(error)", code: 2)
    }
    let img = loadImage(p.positional[0]), dst = p.positional[1]
    let canvas = PreviewCanvas(image: img, maxLong: maxLong)
    let W = canvas.sourceWidth, H = canvas.sourceHeight
    let colors: [UInt32] = [0xFF4D4F, 0xFAAD14, 0x36CFC9]
    var labels: [(String, CGPoint, NSColor)] = []
    let results: [[String: Any]] = boxes.enumerated().map { index, box in
        let geometry = cropGeometry(width: W, height: H, mode: box.mode, aspect: box.aspect ?? 2.35,
                                    anchorX: box.anchor_x, anchorY: box.anchor_y,
                                    zoom: box.zoom, rotate: box.rotate)
        let vertices = geometry.sourceVertices
        let points = vertices.map { CGPoint(x: $0.x / W * canvas.width, y: $0.y / H * canvas.height) }
        let rgb = colors[index % colors.count]
        let color = NSColor(srgbRed: Double(rgb >> 16) / 255, green: Double(rgb >> 8 & 255) / 255,
                            blue: Double(rgb & 255) / 255, alpha: 1)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        canvas.stroke(path, color: color.cgColor, width: max(1.5, canvas.fontSize * 0.12), outline: 1)
        let number = index + 1
        let label = box.label.isEmpty ? "\(number)" : "\(number)  \(box.label)"
        labels.append((label, points[0], color))
        return [
            "number": number, "label": box.label, "mode": geometry.vertical ? "v" : "h",
            "center": geometry.normalizedCenter(sourceWidth: W, sourceHeight: H),
            "cropSourcePixels": geometry.sourcePixels, "anchorClamped": geometry.anchorClamped,
            "effectiveLongEdge": geometry.effectiveLongEdge,
            "vertices": vertices.map { [r4($0.x / W), r4(1 - $0.y / H)] },
        ]
    }
    var occupied: [CGRect] = []
    for (label, point, color) in labels {
        occupied.append(canvas.label(label, at: point, color: color, avoiding: occupied))
    }
    canvas.save(to: dst, quality: quality)
    printJSON(results)
}

// MARK: - grid3x3 / sheet

struct Tile { let label: String; let image: CGImage }

func renderSheet(tiles: [Tile], cols: Int, tileLong: Int, title: String?, numbered: Bool,
                 dst: String, quality: Double) {
    let rows = Int(ceil(Double(tiles.count) / Double(cols)))
    // Use the first image ratio when orientations match, or square cells when they differ.
    let first = tiles[0].image
    let allVertical = tiles.allSatisfy { $0.image.height > $0.image.width }
    let allHorizontal = tiles.allSatisfy { $0.image.height <= $0.image.width }
    let cellAspect = (allVertical || allHorizontal) ? Double(first.width) / Double(first.height) : 1.0
    let cellW = cellAspect >= 1 ? tileLong : Int((Double(tileLong) * cellAspect).rounded())
    let cellH = cellAspect >= 1 ? Int((Double(tileLong) / cellAspect).rounded()) : tileLong

    let unit = Double(max(cellW, cellH))
    let pad = Int((unit * 0.026).rounded())
    let numSize = max(20.0, unit * 0.042)
    let labelSize = max(14.0, unit * 0.024)
    let headerH = Int((numSize * 1.5).rounded())
    let titleSize = max(22.0, unit * 0.036)
    let titleH = title == nil ? 0 : Int((titleSize * 2.0).rounded())
    let totalW = cols * cellW + (cols + 1) * pad
    let totalH = titleH + rows * (cellH + headerH) + (rows + 1) * pad

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: totalW, pixelsHigh: totalH,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        fail("Could not create contact sheet canvas \(totalW)x\(totalH)")
    }
    NSGraphicsContext.saveGraphicsState()
    nsCtx.imageInterpolation = .high
    NSGraphicsContext.current = nsCtx

    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
    NSBezierPath.fill(NSRect(x: 0, y: 0, width: totalW, height: totalH))

    let ink = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    let dim = NSColor(srgbRed: 0.70, green: 0.70, blue: 0.70, alpha: 1)
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingMiddle

    if let title = title {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold),
            .foregroundColor: ink, .paragraphStyle: para,
        ]
        (title as NSString).draw(in: NSRect(x: Double(pad), y: Double(totalH - pad) - titleSize * 1.5,
                                            width: Double(totalW - 2 * pad), height: titleSize * 1.4),
                                 withAttributes: attrs)
    }

    let numAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: numSize, weight: .bold),
        .foregroundColor: ink,
    ]
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: labelSize, weight: .medium),
        .foregroundColor: numbered ? dim : ink, .paragraphStyle: para,
    ]

    for (idx, tile) in tiles.enumerated() {
        let row = idx / cols, col = idx % cols
        let x = Double(pad + col * (cellW + pad))
        let top = Double(totalH - titleH - pad - row * (cellH + headerH + pad))   // Cocoa uses a bottom-left origin.
        let headerBase = top - Double(headerH)
        var textX = x + 2
        if numbered {
            let n = "\(idx + 1)" as NSString
            let size = n.size(withAttributes: numAttrs)
            let numW = Double(size.width), numH = Double(size.height)
            n.draw(at: NSPoint(x: textX, y: headerBase + (Double(headerH) - numH) / 2), withAttributes: numAttrs)
            textX += numW + numSize * 0.45
        }
        if !tile.label.isEmpty {
            let lh = labelSize * 1.35
            (tile.label as NSString).draw(
                in: NSRect(x: textX, y: headerBase + (Double(headerH) - lh) / 2,
                           width: x + Double(cellW) - textX, height: lh),
                withAttributes: labelAttrs)
        }
        // Fit and center the image while preserving its aspect ratio.
        let iw = Double(tile.image.width), ih = Double(tile.image.height)
        let k = min(Double(cellW) / iw, Double(cellH) / ih)
        let dw = iw * k, dh = ih * k
        let rect = NSRect(x: x + (Double(cellW) - dw) / 2,
                          y: headerBase - Double(cellH) + (Double(cellH) - dh) / 2, width: dw, height: dh)
        NSImage(cgImage: tile.image, size: NSSize(width: iw, height: ih)).draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let out = rep.cgImage else { fail("Could not render contact sheet") }
    saveImage(out, to: dst, quality: quality)
    printJSON(["dst": dst, "size": [totalW, totalH], "tiles": tiles.count, "cols": cols, "rows": rows])
}

func loadTiles(_ items: [String]) -> [Tile] {
    items.map { item in
        let (label, path) = splitItem(item)
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Tile(label: label ?? fallback, image: loadImage(path))
    }
}

func runGrid(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["out", "title", "tile-long", "quality"])
    guard let dst = p.options["out"] else { fail("grid3x3 requires --out <dst>", code: 2) }
    guard p.positional.count == 9 else {
        fail("grid3x3 requires exactly nine <label=image> entries. Got \(p.positional.count)", code: 2)
    }
    let tiles: [Tile] = p.positional.map { item in
        let (label, path) = splitItem(item)
        return Tile(label: label ?? "", image: loadImage(path))
    }
    renderSheet(tiles: tiles, cols: 3, tileLong: max(200, p.int("tile-long", 1100)), title: p.options["title"],
                numbered: true, dst: dst, quality: p.double("quality", 0.92))
}

func runSheet(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["out", "cols", "title", "tile-long", "quality"], flagKeys: ["numbered"])
    guard let dst = p.options["out"] else { fail("sheet requires --out <dst>", code: 2) }
    guard !p.positional.isEmpty else { fail("sheet requires at least one image", code: 2) }
    let n = p.positional.count
    let cols = p.int("cols", 0) > 0 ? min(p.int("cols", 0), n) : min(n, max(1, Int(ceil(sqrt(Double(n))))))
    renderSheet(tiles: loadTiles(p.positional), cols: cols, tileLong: max(200, p.int("tile-long", 900)),
                title: p.options["title"], numbered: p.flags.contains("numbered"), dst: dst,
                quality: p.double("quality", 0.92))
}

// MARK: - stats

func runStats(_ argv: [String]) {
    let p = parse(argv, valueKeys: ["clip-hi", "clip-lo", "sample-long"], flagKeys: ["dimensions-only"])
    guard p.positional.count == 1 else { fail("stats requires <img>", code: 2) }
    let path = p.positional[0]
    if p.flags.contains("dimensions-only") {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            fail("Could not read image dimensions: \(path)")
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        printJSON(["path": path, "width": swapped ? h : w, "height": swapped ? w : h])
        return
    }
    let clipHi = p.int("clip-hi", 250), clipLo = p.int("clip-lo", 5)
    let sampleLong = max(64, p.int("sample-long", 2048))
    let img = loadImage(path)
    let k = min(1.0, Double(sampleLong) / Double(max(img.width, img.height)))
    let w = max(1, Int((Double(img.width) * k).rounded())), h = max(1, Int((Double(img.height) * k).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("Could not create statistics canvas for \(path)")
    }
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { fail("Could not decode pixels for \(path)") }
    let bpr = ctx.bytesPerRow
    let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
    var hist = [Int](repeating: 0, count: 256)
    var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumL = 0.0
    var hi = 0, lo = 0, hiAny = 0
    for y in 0..<h {
        var o = y * bpr
        for _ in 0..<w {
            let r = Double(px[o]), g = Double(px[o + 1]), b = Double(px[o + 2])
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b      // Rec. 709 luma from display-encoded values.
            let li = min(255, Int(l.rounded()))
            hist[li] += 1
            sumR += r; sumG += g; sumB += b; sumL += l
            if li >= clipHi { hi += 1 }
            if li <= clipLo { lo += 1 }
            if Int(max(r, g, b)) >= clipHi { hiAny += 1 }
            o += 4
        }
    }
    let n = Double(w * h)
    func pct(_ q: Double) -> Int {
        let target = q * n
        var acc = 0.0
        for i in 0..<256 { acc += Double(hist[i]); if acc >= target { return i } }
        return 255
    }
    let mr = sumR / n, mg = sumG / n, mb = sumB / n
    printJSON([
        "path": path,
        "width": img.width, "height": img.height,
        "sampled": [w, h],
        "lumaMean": r4(sumL / n),
        "p05": pct(0.05), "p50": pct(0.50), "p95": pct(0.95),
        "highlightClip": r4(Double(hi) / n),
        "highlightClipAnyChannel": r4(Double(hiAny) / n),
        "shadowClip": r4(Double(lo) / n),
        "clipThresholds": ["hi": clipHi, "lo": clipLo],
        "meanRGB": [r4(mr), r4(mg), r4(mb)],
        "greenBias": r4(mg - (mr + mb) / 2),
    ])
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { fputs(usage + "\n", stderr); exit(2) }
let rest = Array(argv.dropFirst())
switch cmd {
case "frame": runFrame(rest)
case "grid3x3": runGrid(rest)
case "sheet": runSheet(rest)
case "stats": runStats(rest)
case "ruler": runRuler(rest)
case "preview-boxes": runPreviewBoxes(rest)
case "--version", "version": print("cinema_frame 1.0.0")
case "-h", "--help", "help": print(usage)
default: fail("Unknown command \(cmd). Run --help to see available commands.", code: 2)
}
