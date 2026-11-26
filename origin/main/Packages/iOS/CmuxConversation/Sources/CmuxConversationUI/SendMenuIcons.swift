#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Artwork for the "+" menu's rows, as Messages draws them: a 54 pt image
/// holding a round plate (38.67 pt on iOS 26, 36.67 pt with a gray rim on
/// iOS 27) with full-color app art.
///
/// Camera and Photos use Messages' own images, read by name from the
/// system ChatKit bundle's asset catalog (`send-menu-camera-glass`,
/// `send-menu-photos-glass`, `-calistoga` variants on iOS 27). Only public
/// API is called (`Bundle(path:)`, `UIImage(named:in:compatibleWith:)`); no
/// private code is loaded. When that bundle or image is missing, the same
/// plate is drawn in code. Messages has no Files row, so Files is always
/// drawn in code in the same style: the plate with the Files app's folder.
@MainActor
enum SendMenuIcons {
    enum Kind {
        case camera, photos, files
    }

    static var isIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    static func image(_ kind: Kind) -> UIImage {
        switch kind {
        case .camera: systemImage("send-menu-camera") ?? drawn(kind)
        case .photos: systemImage("send-menu-photos") ?? drawn(kind)
        case .files: drawn(kind)
        }
    }

    private static let chatKit: Bundle? = {
        var path = "/System/Library/PrivateFrameworks/ChatKit.framework"
        #if targetEnvironment(simulator)
        if let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] { path = root + path }
        #endif
        return Bundle(path: path)
    }()

    private static func systemImage(_ base: String) -> UIImage? {
        guard let chatKit else { return nil }
        let name = base + (isIOS27 ? "-glass-calistoga" : "-glass")
        guard let image = UIImage(named: name, in: chatKit, compatibleWith: nil),
              image.size == CGSize(width: SendMenuGeometry.iconSize, height: SendMenuGeometry.iconSize) else { return nil }
        return image
    }

    // MARK: Drawn artwork

    static func drawn(_ kind: Kind) -> UIImage {
        let side = SendMenuGeometry.iconSize
        let iOS27 = isIOS27
        let diameter = SendMenuGeometry.iconDiscDiameter(iOS27: iOS27)
        let disc = CGRect(x: (side - diameter) / 2, y: (side - diameter) / 2, width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            drawPlate(kind, in: disc, iOS27: iOS27, cg)
            switch kind {
            case .camera: drawLens(in: disc, cg)
            case .photos: drawFlower(in: disc, cg)
            case .files: drawFolder(in: disc, cg)
            }
        }
    }

    private static func gradient(_ cg: CGContext, _ colors: [UIColor], from: CGPoint, to: CGPoint) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        cg.drawLinearGradient(gradient, start: from, end: to, options: [])
    }

    private static func gray(_ value: CGFloat) -> UIColor { UIColor(white: value / 255, alpha: 1) }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    /// Messages' plate: white falling to light gray at the bottom; on iOS 27
    /// inside a 1 pt gray rim (sampled from the Photos artwork).
    private static func drawPlate(_ kind: Kind, in disc: CGRect, iOS27: Bool, _ cg: CGContext) {
        cg.saveGState()
        let colors: [UIColor] = kind == .camera
            ? [gray(232), gray(176)]
            : (iOS27 ? [gray(255), gray(246)] : [gray(255), gray(235)])
        if iOS27 {
            cg.addEllipse(in: disc)
            cg.setFillColor(rgb(216, 216, 220).cgColor)
            cg.fillPath()
            let inner = disc.insetBy(dx: 1, dy: 1)
            cg.addEllipse(in: inner)
            cg.clip()
            gradient(cg, colors, from: CGPoint(x: inner.midX, y: inner.minY), to: CGPoint(x: inner.midX, y: inner.maxY))
        } else {
            cg.addEllipse(in: disc)
            cg.clip()
            gradient(cg, colors, from: CGPoint(x: disc.midX, y: disc.minY), to: CGPoint(x: disc.midX, y: disc.maxY))
            // The 1 px white edge highlight.
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            cg.setLineWidth(1 / 3)
            cg.strokeEllipse(in: disc.insetBy(dx: 1 / 6, dy: 1 / 6))
        }
        cg.restoreGState()
    }

    /// The Files app's folder: a back sheet with its tab, a white paper edge
    /// and the front sheet, in the app icon's blues.
    private static func drawFolder(in disc: CGRect, _ cg: CGContext) {
        let width = disc.width * 0.6
        let height = width * 0.74
        let body = CGRect(x: disc.midX - width / 2, y: disc.midY - height / 2 + disc.width * 0.02, width: width, height: height)
        let radius = width * 0.09
        cg.saveGState()
        // Back sheet with the tab on its top left.
        let back = UIBezierPath()
        let tabWidth = width * 0.38, tabHeight = height * 0.12
        back.move(to: CGPoint(x: body.minX, y: body.minY + radius))
        back.addArc(withCenter: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        back.addLine(to: CGPoint(x: body.minX + tabWidth - radius * 0.6, y: body.minY))
        back.addQuadCurve(to: CGPoint(x: body.minX + tabWidth + radius * 0.8, y: body.minY + tabHeight), controlPoint: CGPoint(x: body.minX + tabWidth + radius * 0.2, y: body.minY))
        back.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY + tabHeight))
        back.addArc(withCenter: CGPoint(x: body.maxX - radius, y: body.minY + tabHeight + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        back.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        back.addLine(to: CGPoint(x: body.minX, y: body.maxY - radius))
        back.close()
        cg.addPath(back.cgPath)
        cg.setFillColor(rgb(60, 140, 240).cgColor)
        cg.fillPath()
        // Paper.
        let paperTop = body.minY + height * 0.2
        let paper = UIBezierPath(roundedRect: CGRect(x: body.minX + width * 0.05, y: paperTop, width: width * 0.9, height: height * 0.4), cornerRadius: radius * 0.6)
        cg.addPath(paper.cgPath)
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillPath()
        // Front sheet.
        let frontTop = body.minY + height * 0.27
        let front = UIBezierPath(roundedRect: CGRect(x: body.minX, y: frontTop, width: width, height: body.maxY - frontTop), cornerRadius: radius)
        cg.addPath(front.cgPath)
        cg.clip()
        gradient(cg, [rgb(91, 187, 249), rgb(48, 113, 231)], from: CGPoint(x: body.midX, y: frontTop), to: CGPoint(x: body.midX, y: body.maxY))
        cg.restoreGState()
    }

    /// Fallback for Messages' Camera artwork: a dark lens in a gray barrel.
    private static func drawLens(in disc: CGRect, _ cg: CGContext) {
        cg.saveGState()
        let barrel = disc.insetBy(dx: disc.width * 0.12, dy: disc.width * 0.12)
        cg.addEllipse(in: barrel)
        cg.setFillColor(gray(40).cgColor)
        cg.fillPath()
        let lens = barrel.insetBy(dx: barrel.width * 0.12, dy: barrel.width * 0.12)
        cg.addEllipse(in: lens)
        cg.clip()
        gradient(cg, [rgb(30, 40, 90), rgb(8, 10, 24)], from: CGPoint(x: lens.minX, y: lens.minY), to: CGPoint(x: lens.maxX, y: lens.maxY))
        cg.resetClip()
        let glint = CGRect(x: lens.midX - lens.width * 0.05, y: lens.minY + lens.height * 0.2, width: lens.width * 0.3, height: lens.height * 0.18)
        cg.setFillColor(UIColor(white: 1, alpha: 0.75).cgColor)
        cg.fillEllipse(in: glint)
        cg.restoreGState()
    }

    /// Fallback for Messages' Photos artwork: eight translucent petals.
    private static func drawFlower(in disc: CGRect, _ cg: CGContext) {
        let colors: [UIColor] = [
            rgb(255, 150, 1), rgb(255, 205, 0), rgb(120, 200, 40), rgb(30, 200, 110),
            rgb(0, 165, 235), rgb(140, 110, 220), rgb(240, 100, 170), rgb(250, 80, 80),
        ]
        let center = CGPoint(x: disc.midX, y: disc.midY)
        let petalWidth = disc.width * 0.24, petalLength = disc.width * 0.34
        cg.saveGState()
        for (index, color) in colors.enumerated() {
            cg.saveGState()
            cg.translateBy(x: center.x, y: center.y)
            cg.rotate(by: CGFloat(index) * .pi / 4)
            let petal = UIBezierPath(roundedRect: CGRect(x: -petalWidth / 2, y: -petalLength - disc.width * 0.03, width: petalWidth, height: petalLength), cornerRadius: petalWidth / 2)
            cg.addPath(petal.cgPath)
            cg.setFillColor(color.withAlphaComponent(0.85).cgColor)
            cg.fillPath()
            cg.restoreGState()
        }
        cg.restoreGState()
    }
}
#endif
