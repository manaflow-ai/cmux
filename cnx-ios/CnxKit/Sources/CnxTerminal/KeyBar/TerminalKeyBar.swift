#if os(iOS)
import AudioToolbox
import CnxDesign
import SwiftUI

/// A key of the key bar (SPEC 10.2).
enum KeyBarKey: Hashable, Sendable {
    case escape, tab, shiftTab, control, alternate, up, down, left, right, paste, hideKeyboard
    case chord(Character)
    case symbol(String)

    var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .control: "ctrl"
        case .alternate: "alt"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .paste: "paste"
        case .hideKeyboard: ""
        case .chord(let letter): "^" + String(letter).uppercased()
        case .symbol(let text): text
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .control: "Control"
        case .alternate: "Alt"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .paste: "Paste"
        case .hideKeyboard: "Hide Keyboard"
        case .chord(let letter): "Control " + String(letter).uppercased()
        case .symbol(let text): text
        }
    }

    /// Arrows repeat while held.
    var repeats: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }

    static let middle: [KeyBarKey] = [
        .tab, .shiftTab, .left, .down, .up, .right, .chord("c"), .chord("d"), .chord("z"), .chord("l"), .chord("r"),
        .paste, .symbol("|"), .symbol("~"), .symbol("/"), .symbol("-"), .symbol("`"), .symbol("{"), .symbol("}"),
        .symbol("["), .symbol("]"), .chord("b"),
    ]
}

/// The key bar over the keyboard: fixed esc / ctrl / alt, a scrolling middle,
/// and the joystick plus hide-keyboard at the trailing end, in one glass capsule.
struct TerminalKeyBar: View {
    let model: TerminalModel
    /// Middle-row keys clipped under the pinned keys or the joystick
    /// (`KeyBarClipping`): hidden from accessibility, offered as row actions.
    @State private var clipped: Set<KeyBarKey> = []

    var body: some View {
        HStack(spacing: 6) {
            KeyCap(key: .escape, model: model)
            KeyCap(key: .control, model: model)
            KeyCap(key: .alternate, model: model)
            Divider().frame(height: 22)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(KeyBarKey.middle, id: \.self) { key in
                        KeyCap(key: key, model: model)
                            .onGeometryChange(for: Bool.self) { proxy in
                                KeyBarClipping().isActivatable(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                            } action: { visible in
                                if visible { clipped.remove(key) } else { clipped.insert(key) }
                            }
                            .accessibilityHidden(clipped.contains(key))
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled(false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("More keys")
            .accessibilityActions {
                ForEach(KeyBarKey.middle.filter { clipped.contains($0) }, id: \.self) { key in
                    Button(key.accessibilityLabel) { model.keyBar(key) }
                }
            }
            Divider().frame(height: 22)
            Joystick(engine: model.joystickEngine)
            Button {
                model.keyBar(.hideKeyboard)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 5)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 8)
        .tint(.primary)
    }
}

/// One key cap: 40 x 34 (wider for words), radius 10, `fill`; pressed: `fillPressed` + 0.92.
/// A Button keeps the middle row scrollable; arrows repeat while held.
struct KeyCap: View {
    let key: KeyBarKey
    let model: TerminalModel
    @State private var taps = 0
    @AppStorage(CnxPreferences.Key.keyClicks) private var keyClicks = CnxPreferences.defaultKeyClicks

    private var stickyState: TerminalStickyModifiers.State? {
        switch key {
        case .control: model.sticky.control
        case .alternate: model.sticky.alternate
        default: nil
        }
    }

    var body: some View {
        let state = stickyState
        let locked = state == .locked
        let armed = if case .armed = state { true } else { false }
        Button {
            taps += 1
            if keyClicks { KeyClick.play() }
            model.keyBar(key)
        } label: {
            Text(key.label)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(locked ? Color(uiColor: .systemBackground) : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed))
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(locked ? "Locked" : armed ? "On for the next key" : "")
    }
}

/// The system keyboard's click (Settings → Terminal → Key clicks). The key
/// bar is not the keyboard's input view, so `UIDevice.playInputClick` stays
/// silent for it; this plays the same system sound, which follows the
/// ring/silent switch.
enum KeyClick {
    /// `Tock`, the keyboard key click.
    private static let sound: SystemSoundID = 1104

    static func play() { AudioServicesPlaySystemSound(sound) }
}

struct KeyCapStyle: ButtonStyle {
    var locked = false
    var armed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(locked ? AnyShapeStyle(Color.primary)
                          : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.22 : armed ? 0.16 : 0.08)))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(.rect)
    }
}
#endif
