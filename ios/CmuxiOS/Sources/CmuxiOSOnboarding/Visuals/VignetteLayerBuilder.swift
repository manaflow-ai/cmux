import UIKit

/// Builds the vignette's layers and its looping keyframe animations. Every
/// animated property gets one keyframe animation spanning the loop period,
/// so overlapping phases never fight over a key path.
@MainActor
struct VignetteLayerBuilder {
    let layout: VignetteLayout
    let colors: VignetteColors
    let script: VignetteScript
    let scale: CGFloat

    func build(in frame: CGRect) -> VignetteScene {
        let root = CALayer()
        root.frame = frame
        root.backgroundColor = colors.window
        root.cornerRadius = layout.corner
        root.cornerCurve = .continuous
        root.borderWidth = 1 / max(scale, 1)
        root.borderColor = colors.border
        root.masksToBounds = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: 14 + CGFloat(index) * 14, y: 14, width: 8, height: 8)
            dot.cornerRadius = 4
            dot.backgroundColor = colors.dots
            root.addSublayer(dot)
        }

        let content = CALayer()
        content.frame = root.bounds
        root.addSublayer(content)

        let promptWidth = layout.characterWidth * CGFloat(script.prompt.count)
        content.addSublayer(text(script.prompt, color: colors.secondary, frame: layout.lineFrame(0)))
        let command = text(script.command, color: colors.text, frame: layout.lineFrame(0, x: promptWidth))
        let mask = CALayer()
        mask.backgroundColor = UIColor.black.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0)
        mask.frame = command.bounds
        command.mask = mask
        content.addSublayer(command)

        let cursor = CALayer()
        let line0 = layout.lineFrame(0, x: promptWidth)
        cursor.anchorPoint = CGPoint(x: 0, y: 0.5)
        cursor.bounds = CGRect(x: 0, y: 0, width: layout.characterWidth, height: layout.font.lineHeight)
        cursor.position = CGPoint(x: line0.minX, y: line0.minY + layout.font.lineHeight / 2 + 1)
        cursor.backgroundColor = colors.secondary
        content.addSublayer(cursor)

        let agentLines = script.agentLines.enumerated().map { index, line in
            text(line, color: index == 2 ? colors.waiting : colors.secondary, frame: layout.lineFrame(index + 1))
        }
        agentLines.forEach(content.addSublayer)

        let result = CALayer()
        result.frame = layout.lineFrame(4)
        let check = text(script.check, color: colors.success, frame: CGRect(x: 0, y: 0, width: layout.characterWidth * 2, height: layout.lineHeight))
        let passed = text(OnboardingText.resultAllowed, color: colors.text,
                          frame: CGRect(x: layout.characterWidth * 2, y: 0, width: result.bounds.width - layout.characterWidth * 2, height: layout.lineHeight))
        result.addSublayer(check)
        result.addSublayer(passed)
        content.addSublayer(result)

        let (card, allow) = makeCard()
        content.addSublayer(card)

        return VignetteScene(root: root, content: content, commandMask: mask, cursor: cursor,
                             agentLines: agentLines, card: card, allow: allow, result: result)
    }

    // MARK: - Animation

    func animate(_ scene: VignetteScene, begin: CFTimeInterval) {
        let s = script
        let fullWidth = scene.commandMask.bounds.width
        scene.commandMask.bounds.size.width = 0

        // Typing: the mask reveals one character per step; the cursor follows.
        let count = s.command.count
        var times: [CFTimeInterval] = [0]
        var widths: [CGFloat] = [0]
        var cursorX: [CGFloat] = [scene.cursor.position.x]
        for index in 1...count {
            times.append(s.typingStart + CFTimeInterval(index) * OnboardingMotion.typePerCharacter)
            widths.append(min(fullWidth, CGFloat(index) * layout.characterWidth))
            cursorX.append(scene.cursor.position.x + CGFloat(index) * layout.characterWidth)
        }
        add(discrete("bounds.size.width", times: times, values: widths), to: scene.commandMask, begin: begin)
        add(discrete("position.x", times: times, values: cursorX), to: scene.cursor, begin: begin)
        add(discrete("opacity", times: [0, 0.4, s.typingStart, s.agentLineStarts[0]], values: [1, 0, 1, 0]), to: scene.cursor, begin: begin)

        for (layer, start) in zip(scene.agentLines, s.agentLineStarts) {
            add(fadeIn(at: start), to: layer, begin: begin)
        }
        add(fadeIn(at: s.result), to: scene.result, begin: begin)

        // Card: rises in, the Allow pill is pressed, the card drops away.
        let rise = OnboardingMotion.cardRise
        let y = scene.card.position.y
        add(keyframes("opacity", [(0, 0), (s.cardIn, 0), (s.cardIn + 0.2, 1), (s.cardOut, 1), (s.cardOut + 0.2, 0)]), to: scene.card, begin: begin)
        add(keyframes("position.y", [(0, y + rise), (s.cardIn, y + rise), (s.cardIn + 0.3, y), (s.cardOut, y), (s.cardOut + 0.2, y + rise)]),
            to: scene.card, begin: begin)
        add(keyframes("transform.scale", [(0, 1), (s.press, 1), (s.press + 0.08, 0.9), (s.press + 0.22, 1)]), to: scene.allow, begin: begin)

        // The whole scene fades before the loop restarts.
        add(keyframes("opacity", [(0, 1), (s.fadeOut, 1), (s.fadeOut + s.fadeOutLength, 0), (s.period, 0)]), to: scene.content, begin: begin)
    }

    /// Reduce Motion: the approval moment, still.
    func applyStillFrame(_ scene: VignetteScene) {
        scene.cursor.opacity = 0
        scene.result.opacity = 0
    }

    // MARK: - Helpers

    private func text(_ string: String, color: CGColor, frame: CGRect, alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.frame = frame
        layer.string = string
        layer.font = layout.font
        layer.fontSize = layout.font.pointSize
        layer.foregroundColor = color
        layer.contentsScale = scale
        layer.alignmentMode = alignment
        layer.truncationMode = .end
        return layer
    }

    private func makeCard() -> (CALayer, CALayer) {
        let frame = layout.cardFrame
        let card = CALayer()
        card.frame = frame
        card.backgroundColor = colors.card
        card.cornerRadius = 12
        card.cornerCurve = .continuous
        card.shadowColor = UIColor.black.cgColor
        card.shadowOpacity = 0.12
        card.shadowRadius = 8
        card.shadowOffset = CGSize(width: 0, height: 2)

        let pillHeight = ceil(layout.font.lineHeight + 10)
        let pillWidth = max(56, layout.characterWidth * 7)
        let pillY = (frame.height - pillHeight) / 2
        let allow = pill(OnboardingText.allow, fill: colors.ink, textColor: colors.paper,
                         frame: CGRect(x: frame.width - 10 - pillWidth, y: pillY, width: pillWidth, height: pillHeight))
        let deny = pill(OnboardingText.deny, fill: colors.pill, textColor: colors.text,
                        frame: CGRect(x: frame.width - 18 - pillWidth * 2, y: pillY, width: pillWidth, height: pillHeight))
        let titleWidth = max(0, deny.frame.minX - 22)
        let title = text(OnboardingText.approveCardTitle, color: colors.text,
                         frame: CGRect(x: 12, y: (frame.height - layout.lineHeight) / 2 + 2, width: titleWidth, height: layout.lineHeight))
        card.addSublayer(title)
        card.addSublayer(deny)
        card.addSublayer(allow)
        return (card, allow)
    }

    private func pill(_ title: String, fill: CGColor, textColor: CGColor, frame: CGRect) -> CALayer {
        let pill = CALayer()
        pill.frame = frame
        pill.backgroundColor = fill
        pill.cornerRadius = frame.height / 2
        let label = text(title, color: textColor,
                         frame: CGRect(x: 0, y: (frame.height - layout.font.lineHeight) / 2, width: frame.width, height: layout.font.lineHeight + 2),
                         alignment: .center)
        pill.addSublayer(label)
        return pill
    }

    private func fadeIn(at start: CFTimeInterval) -> CAKeyframeAnimation {
        keyframes("opacity", [(0, 0), (start, 0), (start + OnboardingMotion.lineFade, 1), (script.period, 1)])
    }

    /// Linear keyframes need key times from 0 to 1: the last value holds to the period's end.
    private func keyframes(_ keyPath: String, _ input: [(CFTimeInterval, CGFloat)]) -> CAKeyframeAnimation {
        var points = input
        if let last = points.last, last.0 < script.period { points.append((script.period, last.1)) }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = points.map(\.1)
        animation.keyTimes = points.map { NSNumber(value: $0.0 / script.period) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: max(points.count - 1, 1))
        return animation
    }

    private func discrete(_ keyPath: String, times: [CFTimeInterval], values: [CGFloat]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.calculationMode = .discrete
        animation.values = values
        // Discrete mode takes one more key time than values, ending at 1.
        animation.keyTimes = (times + [script.period]).map { NSNumber(value: $0 / script.period) }
        return animation
    }

    private func add(_ animation: CAKeyframeAnimation, to layer: CALayer, begin: CFTimeInterval) {
        animation.duration = script.period
        animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(begin, from: nil)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: animation.keyPath)
    }
}
