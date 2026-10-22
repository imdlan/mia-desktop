// Renders Mia's app icon at every size an .icns needs, from a finished logo
// source image (RGBA PNG, squircle-cropped, transparent outside the shape).
//
//   swift Resources/make-icon.swift <source.png> <out.iconset>
//   iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
//
// The source art is normalised before scaling: the opaque block is detected,
// rescaled to Apple's canonical 824/1024 art width, and re-centred on a fresh
// 1024 canvas — so a logo authored slightly larger or off-centre still sits in
// the Dock exactly as tall as the system icons beside it. Sizes below 128 skip
// nothing here (the source is a finished raster); small sizes rely on Core
// Graphics' high-quality downsampling, which keeps the silhouette readable.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <source.png> <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let source = NSImage(contentsOf: sourceURL),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("error: cannot read \(args[1]) as PNG\n".data(using: .utf8)!)
    exit(1)
}

// --- Normalise: find the opaque art block, scale to 824/1024, centre it ------

/// Bounding box of pixels above the alpha threshold, in CG coordinates
/// (origin bottom-left), computed from a downscaled probe — exact to a couple
/// of pixels, which the 9% margin absorbs easily.
func artBlock(of image: CGImage, alphaThreshold: UInt8 = 16) -> CGRect? {
    let probe = 256
    guard let ctx = CGContext(data: nil, width: probe, height: probe,
                              bitsPerComponent: 8, bytesPerRow: probe * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: probe * probe * 4)
    var minX = probe, minY = probe, maxX = -1, maxY = -1
    for y in 0..<probe {
        for x in 0..<probe {
            if px[(y * probe + x) * 4 + 3] >= alphaThreshold {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let scale = CGFloat(image.width) / CGFloat(probe)
    return CGRect(x: CGFloat(minX) * scale, y: CGFloat(minY) * scale,
                  width: CGFloat(maxX - minX + 1) * scale,
                  height: CGFloat(maxY - minY + 1) * scale)
}

let canvas = 1024
let canonicalArt: CGFloat = 824   // Apple's macOS template art width
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// The art block drawn centred at canonical size on a transparent 1024 canvas.
// Aspect ratio is preserved (fit, not fill); a square logo fills all 824.
func normalised(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let art = artBlock(of: cg) ?? CGRect(x: 82, y: 82, width: 860, height: 860)
    // fit maps SOURCE pixels → canvas pixels: the art block ends up canonical
    // (824/1024) wide. The draw call below scales the WHOLE 1024 source image
    // (margins included), so the dest side is 1024·fit, not art.width·fit —
    // sizing dest by the block alone shrinks the art by the block's share of
    // the canvas (~19%) and the icon reads small in the Dock.
    let fit = min(canonicalArt / art.width, canonicalArt / art.height) * (s / 1024)
    let drawW = CGFloat(cg.width) * fit, drawH = CGFloat(cg.height) * fit
    // Centre by the art block's centre, not the whole image's — the source
    // margins are uneven, and optical centring follows the visible block.
    let dest = CGRect(x: s / 2 - art.midX * fit,
                      y: s / 2 - art.midY * fit,
                      width: drawW, height: drawH)
    ctx.draw(cg, in: dest)

    // Below ~32px, downsampling averages the two white dots (each ~1px at 16)
    // into the purple bubble until the icon is a flat blob. Re-draw them from
    // FIXED geometry instead of detection: the source carries other whitish
    // regions (top sheen, the bubble's notch) and any centroid-based hunt
    // drifts off the real dots. The ratios below are measured off the 512px
    // render, where the downsampled dots are still sharp: dot centres at
    // x = 0.365 / 0.635 of the art width (symmetric), y = 0.477, diameter
    // 0.176 of the art width.
    if size <= 32 {
        let artDest = CGRect(x: dest.minX + art.minX * fit,
                             y: dest.minY + art.minY * fit,
                             width: art.width * fit, height: art.height * fit)
        let dotCentres = [CGPoint(x: 0.365, y: 0.477), CGPoint(x: 0.635, y: 0.477)]
        let spread = (dotCentres[1].x - dotCentres[0].x) * artDest.width
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        if spread >= 6.0 {
            // Two dots only when the canvas can hold them AND the purple gap
            // between them; cap at 40% of the spread so it always does.
            let d = min(0.176 * artDest.width, spread * 0.40)
            for c in dotCentres {
                let cx = artDest.minX + c.x * artDest.width
                let cy = artDest.minY + c.y * artDest.height
                ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            }
        } else {
            // 16px canvas: two ~1.7px dots are sub-pixel and the white mixes
            // away into the purple — one solid centred dot reads cleaner.
            let d = CGFloat(size <= 16 ? 2.5 : 2.4)
            let cx = artDest.midX, cy = artDest.minY + 0.477 * artDest.height
            ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        }
    }
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = normalised(size: px)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote 10 sizes to \(outDir.path) (art normalised to \(Int(canonicalArt))/\(canvas))")
