import AppKit

let size = 1_024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: size * 4, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGPath(roundedRect: CGRect(x: 75, y: 75, width: 874, height: 874),
                  cornerWidth: 200, cornerHeight: 200, transform: nil)
let teal = CGColor(red: 0.03, green: 0.42, blue: 0.39, alpha: 1)
let mint = CGColor(red: 0.18, green: 0.66, blue: 0.54, alpha: 1)
let gradient = CGGradient(colorsSpace: space, colors: [teal, mint] as CFArray, locations: [0, 1])!
bitmap.saveGState()
bitmap.addPath(tile)
bitmap.clip()
bitmap.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 140),
                          end: CGPoint(x: 850, y: 970), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
bitmap.restoreGState()
bitmap.setStrokeColor(CGColor(red: 0.82, green: 0.99, blue: 0.92, alpha: 0.65))
bitmap.setLineWidth(4)
bitmap.addPath(tile)
bitmap.strokePath()

let outline = CGPath(roundedRect: CGRect(x: 234, y: 315, width: 556, height: 394),
                    cornerWidth: 83, cornerHeight: 83, transform: nil)
bitmap.addPath(outline)
bitmap.setFillColor(CGColor(red: 0.02, green: 0.30, blue: 0.30, alpha: 0.84))
bitmap.fillPath()
bitmap.setLineCap(.round)
bitmap.setLineWidth(27)
bitmap.setStrokeColor(CGColor(red: 0.94, green: 1, blue: 0.98, alpha: 1))
for (index, height) in [47.0, 90.0, 145.0, 102.0, 180.0, 115.0, 67.0].enumerated() {
    let x = Double(337 + index * 58)
    bitmap.move(to: CGPoint(x: x, y: 512 - height / 2))
    bitmap.addLine(to: CGPoint(x: x, y: 512 + height / 2))
}
bitmap.strokePath()
let data = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
