import Foundation

@main
struct TextBoxChromeBackgroundPolicyRegressionTest {
    static func main() {
        let actual = TextBoxInputChromeBackgroundPolicy.style(glassEffectAvailable: true)
        if actual != .materialFallback {
            fputs(
                "expected TextBox chrome to use materialFallback when glass is available, got \(actual)\n",
                stderr
            )
            exit(1)
        }
    }
}
