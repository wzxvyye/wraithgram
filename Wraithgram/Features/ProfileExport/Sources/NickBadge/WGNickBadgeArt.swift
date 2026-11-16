import Foundation
import UIKit

// The badge pictures, drawn in code (no assets, sharp at any size): the GCONNECT wraith for a
// supporter, the wraith cut out of a wavy seal for the team, the owner's own picture for a custom
// badge (recoloured when the admins approved it as tinted). The canvas is never narrower than it is
// tall, so every slot can treat the badge as a square-ish glyph one line high.
//
// Every call is safe from any thread (layout passes run off the main thread). Results are cached
// by a small hashable key — no string formatting per call.

private struct WGNickBadgeArtKey: Hashable {
    let kind: UInt8
    /// Height in half points.
    let halfPoints: Int
    let rgb: UInt32
    let imageId: String?
}

enum WGNickBadgeArt {
    private static let lock = WGProfileExportLock()
    private static var cache: [WGNickBadgeArtKey: UIImage] = [:]
    private static let cacheLimit = 256

    /// The badge `height` points tall. A custom picture that is not in memory yet is drawn as the
    /// supporter wraith in the owner's colour, and its loading is started.
    static func image(for badge: WGNickBadge, height: CGFloat) -> UIImage {
        let halfPoints = max(12, Int((height * 2.0).rounded()))
        let rgb = badge.colorRGB
        switch badge.kind {
        case .team:
            return WGNickBadgeArt.cached(WGNickBadgeArtKey(kind: 1, halfPoints: halfPoints, rgb: rgb, imageId: nil)) {
                WGNickBadgeArt.drawTeam(height: CGFloat(halfPoints) / 2.0, rgb: rgb)
            }
        case .custom:
            if let imageId = badge.imageId, let source = WGNickBadgeImages.shared.source(for: imageId) {
                let keyColor: UInt32 = badge.tinted ? rgb : 0xFFFFFFFF
                return WGNickBadgeArt.cached(WGNickBadgeArtKey(kind: 2, halfPoints: halfPoints, rgb: keyColor, imageId: imageId)) {
                    WGNickBadgeArt.drawCustom(source: source, tinted: badge.tinted, height: CGFloat(halfPoints) / 2.0, rgb: rgb)
                }
            }
            fallthrough
        case .supporter:
            return WGNickBadgeArt.cached(WGNickBadgeArtKey(kind: 0, halfPoints: halfPoints, rgb: rgb, imageId: nil)) {
                WGNickBadgeArt.drawSupporter(height: CGFloat(halfPoints) / 2.0, rgb: rgb)
            }
        }
    }

    /// The supporter wraith in the default colour (the badge screen, before a badge exists).
    static func sampleImage(height: CGFloat) -> UIImage {
        let badge = WGNickBadge(kind: .supporter, imageId: nil, tinted: false, colorRGB: WGNickBadge.defaultColorRGB, text: nil)
        return WGNickBadgeArt.image(for: badge, height: height)
    }

    /// Drops every cached picture (a picture arrived; colours do not change otherwise).
    static func purgeCustom() {
        WGNickBadgeArt.lock.withLock {
            WGNickBadgeArt.cache = WGNickBadgeArt.cache.filter { $0.key.imageId == nil }
        }
    }

    private static func cached(_ key: WGNickBadgeArtKey, _ make: () -> UIImage) -> UIImage {
        if let image = WGNickBadgeArt.lock.withLock({ WGNickBadgeArt.cache[key] }) {
            return image
        }
        let image = make()
        WGNickBadgeArt.lock.withLock {
            if WGNickBadgeArt.cache.count >= WGNickBadgeArt.cacheLimit {
                WGNickBadgeArt.cache.removeAll(keepingCapacity: true)
            }
            WGNickBadgeArt.cache[key] = image
        }
        return image
    }

    static func color(_ rgb: UInt32) -> UIColor {
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255.0, green: CGFloat((rgb >> 8) & 0xFF) / 255.0, blue: CGFloat(rgb & 0xFF) / 255.0, alpha: 1.0)
    }

    /// Near-white and near-black badges get a soft rim of the opposite tone, so a white badge does
    /// not vanish in a light theme and a black one in a dark theme.
    private static func rim(for rgb: UInt32, height: CGFloat) -> (color: UIColor, radius: CGFloat)? {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let radius = max(1.0, height * 0.08)
        if luma >= 0.8 {
            return (UIColor(white: 0.0, alpha: 0.45), radius)
        }
        if luma <= 0.16 {
            return (UIColor(white: 1.0, alpha: 0.6), radius)
        }
        return nil
    }

    private static func render(size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext)
        }
    }

    // MARK: - Shapes

    /// The wraith in `box`: a round top, straight sides, four legs of different length.
    private static func wraithPath(in box: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let radius = box.width / 2.0
        let shoulder = box.minY + radius
        let hem = box.minY + box.height * 0.64
        path.move(to: CGPoint(x: box.minX, y: hem))
        path.addLine(to: CGPoint(x: box.minX, y: shoulder))
        path.addArc(withCenter: CGPoint(x: box.midX, y: shoulder), radius: radius, startAngle: .pi, endAngle: 0.0, clockwise: true)
        path.addLine(to: CGPoint(x: box.maxX, y: hem))
        path.close()

        let gap = box.width * 0.06
        let legWidth = (box.width - gap * 3.0) / 4.0
        let lengths: [CGFloat] = [0.86, 1.0, 0.92, 0.8]
        for index in 0 ..< 4 {
            let x = box.minX + CGFloat(index) * (legWidth + gap)
            let top = hem - legWidth
            let bottom = box.minY + box.height * lengths[index]
            path.append(UIBezierPath(roundedRect: CGRect(x: x, y: top, width: legWidth, height: bottom - top), byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: legWidth / 2.0, height: legWidth / 2.0)))
        }
        return path
    }

    private static func eyesPath(in box: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let width = box.width * 0.16
        let height = box.height * 0.21
        let top = box.minY + box.height * 0.25
        for centerX in [box.minX + box.width * 0.34, box.minX + box.width * 0.66] {
            path.append(UIBezierPath(roundedRect: CGRect(x: centerX - width / 2.0, y: top, width: width, height: height), cornerRadius: width / 2.0))
        }
        return path
    }

    private static func sealPath(in square: CGRect) -> UIBezierPath {
        let center = CGPoint(x: square.midX, y: square.midY)
        let outer = square.width / 2.0
        let inner = outer * 0.87
        let bumps = 12
        let steps = bumps * 8
        let path = UIBezierPath()
        for step in 0 ... steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2.0 * .pi - .pi / 2.0
            let wave = (cos(angle * CGFloat(bumps)) + 1.0) / 2.0
            let radius = inner + (outer - inner) * wave
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.close()
        return path
    }

    // MARK: - Badges

    private static func drawSupporter(height: CGFloat, rgb: UInt32) -> UIImage {
        let rim = WGNickBadgeArt.rim(for: rgb, height: height)
        let inset = rim?.radius ?? 0.0
        let wraithHeight = (height - inset * 2.0) * 0.92
        let wraithWidth = wraithHeight * 0.8
        let box = CGRect(x: (height - wraithWidth) / 2.0, y: (height - wraithHeight) / 2.0, width: wraithWidth, height: wraithHeight)
        return WGNickBadgeArt.render(size: CGSize(width: height, height: height)) { context in
            context.saveGState()
            if let rim = rim {
                context.setShadow(offset: CGSize(), blur: rim.radius, color: rim.color.cgColor)
            }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(WGNickBadgeArt.color(rgb).cgColor)
            context.addPath(WGNickBadgeArt.wraithPath(in: box).cgPath)
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(WGNickBadgeArt.eyesPath(in: box).cgPath)
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func drawTeam(height: CGFloat, rgb: UInt32) -> UIImage {
        let rim = WGNickBadgeArt.rim(for: rgb, height: height)
        let inset = rim?.radius ?? 0.0
        let side = (height - inset * 2.0) * 0.98
        let square = CGRect(x: (height - side) / 2.0, y: (height - side) / 2.0, width: side, height: side)
        let wraithHeight = side * 0.52
        let wraithWidth = wraithHeight * 0.78
        let wraith = CGRect(x: square.midX - wraithWidth / 2.0, y: square.midY - wraithHeight / 2.0, width: wraithWidth, height: wraithHeight)
        return WGNickBadgeArt.render(size: CGSize(width: height, height: height)) { context in
            context.saveGState()
            if let rim = rim {
                context.setShadow(offset: CGSize(), blur: rim.radius, color: rim.color.cgColor)
            }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let fill = WGNickBadgeArt.color(rgb).cgColor
            context.setFillColor(fill)
            context.addPath(WGNickBadgeArt.sealPath(in: square).cgPath)
            context.fillPath()
            // The wraith is cut out of the seal; its eyes stay in colour.
            context.setBlendMode(.clear)
            context.addPath(WGNickBadgeArt.wraithPath(in: wraith).cgPath)
            context.fillPath()
            context.setBlendMode(.normal)
            context.setFillColor(fill)
            context.addPath(WGNickBadgeArt.eyesPath(in: wraith).cgPath)
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func drawCustom(source: UIImage, tinted: Bool, height: CGFloat, rgb: UInt32) -> UIImage {
        let aspect = min(4.0, max(0.25, source.size.width / max(1.0, source.size.height)))
        let rim = tinted ? WGNickBadgeArt.rim(for: rgb, height: height) : nil
        let inset = rim?.radius ?? 0.0
        let pictureHeight = height - inset * 2.0
        let pictureWidth = (pictureHeight * aspect * 2.0).rounded() / 2.0
        let size = CGSize(width: max(height, pictureWidth + inset * 2.0), height: height)
        let rect = CGRect(x: (size.width - pictureWidth) / 2.0, y: inset, width: pictureWidth, height: pictureHeight)
        if !tinted {
            return WGNickBadgeArt.render(size: size) { _ in
                source.draw(in: rect)
            }
        }
        // Only the picture's alpha survives: the owner's colour is filled into it.
        let glyph = WGNickBadgeArt.render(size: size) { context in
            source.draw(in: rect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(WGNickBadgeArt.color(rgb).cgColor)
            context.fill(CGRect(origin: CGPoint(), size: size))
        }
        guard let rim = rim else {
            return glyph
        }
        return WGNickBadgeArt.render(size: size) { context in
            context.setShadow(offset: CGSize(), blur: rim.radius, color: rim.color.cgColor)
            glyph.draw(at: CGPoint())
        }
    }
}
