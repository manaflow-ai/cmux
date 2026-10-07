import QuartzCore

/// The vignette's layers, kept so the builder can animate them.
struct VignetteScene {
    let root: CALayer
    let content: CALayer
    let commandMask: CALayer
    let cursor: CALayer
    let agentLines: [CALayer]
    let card: CALayer
    let allow: CALayer
    let result: CALayer
}
