import CmuxConversationCore
@testable import CmuxConversationGeometry
import QuartzCore
import XCTest

/// An effect glyph rests (identity, opaque) for most of its 3 s loop, and
/// every 60 Hz rest frame was sent to the render server as a keyframe: an
/// effect row's first commit encoded ~181 transforms per glyph. Only frames
/// that interpolate to something other than their neighbors carry motion.
final class ConversationTextEffectKeyframesTests: XCTestCase {
    private func lerp(_ a: CATransform3D, _ b: CATransform3D, _ f: Double) -> [Double] {
        let x = components(a), y = components(b)
        return zip(x, y).map { $0 + ($1 - $0) * f }
    }

    private func components(_ m: CATransform3D) -> [Double] {
        [m.m11, m.m12, m.m13, m.m14, m.m21, m.m22, m.m23, m.m24, m.m31, m.m32, m.m33, m.m34, m.m41, m.m42, m.m43, m.m44].map { Double($0) }
    }

    /// Linear keyframe interpolation, as Core Animation's linear calculation mode.
    private func sample<T>(_ times: [Double], _ values: [T], at t: Double, lerp: (T, T, Double) -> [Double], single: (T) -> [Double]) -> [Double] {
        guard let last = times.indices.last else { return [] }
        if t <= times[0] { return single(values[0]) }
        if t >= times[last] { return single(values[last]) }
        let upper = times.firstIndex { $0 >= t }!
        if times[upper] == t { return single(values[upper]) }
        let lower = upper - 1
        return lerp(values[lower], values[upper], (t - times[lower]) / (times[upper] - times[lower]))
    }

    func testRestFramesAreNotEncodedAndMotionIsUnchanged() {
        let full = (0...180).map { Double($0) / 60 / ConversationTextEffectMotion.cycle }
        for effect in ConversationTextEffect.allCases {
            for (index, count) in [(0, 1), (3, 12), (40, 58)] {
                let keyframes = ConversationTextEffectLayer.loopKeyframes(effect, index: index, count: count, fontSize: 17, seed: 0xC0FFEE)
                // Every 60 Hz frame of the cycle (and between frames) samples
                // the same pose from the kept keyframes as from all of them.
                var reference = ConversationTextEffectLayer.LoopKeyframes(transformTimes: [], transforms: [], opacityTimes: [], opacities: [])
                for frame in 0...180 {
                    let t = Double(frame) / 60
                    let pose = ConversationTextEffectMotion.pose(effect, index: index, count: count, time: t, seed: 0xC0FFEE)
                    var m = CATransform3DMakeTranslation(CGFloat(pose.dx) * 17, CGFloat(pose.dy) * 17, 0)
                    m = CATransform3DRotate(m, CGFloat(pose.rotation), 0, 0, 1)
                    m = CATransform3DScale(m, CGFloat(pose.scale), CGFloat(pose.scale), 1)
                    reference.transforms.append(m)
                    reference.opacities.append(pose.opacity)
                }
                for step in 0...720 {
                    let t = Double(step) / 720
                    let want = sample(full, reference.transforms, at: t, lerp: lerp, single: components)
                    let got = sample(keyframes.transformTimes, keyframes.transforms, at: t, lerp: lerp, single: components)
                    XCTAssertEqual(got, want, "\(effect) unit \(index)/\(count) transform at \(t)")
                    let wantOpacity = sample(full, reference.opacities, at: t, lerp: { [$0 + ($1 - $0) * $2] }, single: { [$0] })
                    let gotOpacity = keyframes.opacities.isEmpty ? [1] : sample(keyframes.opacityTimes, keyframes.opacities, at: t, lerp: { [$0 + ($1 - $0) * $2] }, single: { [$0] })
                    XCTAssertEqual(gotOpacity, wantOpacity, "\(effect) unit \(index)/\(count) opacity at \(t)")
                }
                // No effect moves a glyph for more than 1.2 s of the 3 s loop.
                XCTAssertLessThanOrEqual(keyframes.transforms.count, 80, "\(effect) unit \(index)/\(count)")
                if !reference.opacities.contains(where: { $0 != 1 }) {
                    XCTAssertTrue(keyframes.opacities.isEmpty, "\(effect) never fades, so it carries no opacity track")
                }
            }
        }
    }
}
