#if os(iOS)
import AudioToolbox
import CnxDesign
import SwiftUI

/// The key bar over the keyboard (SPEC B2): pinned `esc` `ctrl` `^C`, a
/// full-width scroller that snaps to whole keys and fades its edges, and the
/// joystick plus hide-keyboard at the trailing end, in one glass capsule.
struct TerminalKeyBar: View {
    let model: TerminalModel
    /// Middle-row keys clipped at the scroller's edges (`KeyBarClipping`):
    /// hidden from accessibility, offered as row actions.
    @State private var clipped: Set<KeyBarKey> = []
    @State private var edges = KeyBarScrollEdges()
    /// Keys the scroller's edges cut (not wholly visible).
    @State private var cut: Set<KeyBarKey> = []
    /// The row is being dragged or is decelerating or snapping.
    @State private var scrolling = false
    /// Key widths, for spreading the settled row's leftover (R3-5).
    @State private var widths: [KeyBarKey: CGFloat] = [:]

    private var spread: [CGFloat] {
        guard !scrolling, widths.count == KeyBarKey.middle.count else { return [] }
        return KeyBarSpread().shifts(widths: KeyBarKey.middle.map { widths[$0] ?? 40 }, spacing: 6,
                                     contentOffset: edges.offset, visibleWidth: edges.visibleWidth)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(KeyBarKey.pinned, id: \.self) { key in
                KeyCap(key: key, model: model)
            }
            ScrollView(.horizontal) {
                let shifts = spread
                HStack(spacing: 6) {
                    ForEach(Array(KeyBarKey.middle.enumerated()), id: \.element) { index, key in
                        let hidesCut = !scrolling && cut.contains(key)
                        let shift = index < shifts.count ? shifts[index] : 0
                        KeyCap(key: key, model: model)
                            .onGeometryChange(for: Bool.self) { proxy in
                                KeyBarClipping().isActivatable(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                            } action: { visible in
                                if visible { clipped.remove(key) } else { clipped.insert(key) }
                            }
                            .onGeometryChange(for: Bool.self) { proxy in
                                KeyBarClipping().isWhole(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                            } action: { whole in
                                if whole { cut.remove(key) } else { cut.insert(key) }
                            }
                            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                                widths[key] = width
                            }
                            // At rest, a key the edge cuts is not drawn: no sliver (R2-4),
                            // and the leftover is spread over the gaps (R3-5).
                            .opacity(hidesCut ? 0 : 1)
                            .offset(x: shift)
                            .animation(.easeOut(duration: 0.12), value: shift)
                            .animation(.easeOut(duration: 0.12), value: hidesCut)
                            .accessibilityHidden(clipped.contains(key) || hidesCut)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .onScrollPhaseChange { _, phase in
                scrolling = phase != .idle
            }
            .onScrollGeometryChange(for: KeyBarScrollEdges.self) { geometry in
                KeyBarScrollEdges(offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                                  visibleWidth: geometry.containerSize.width)
            } action: { _, new in
                edges = new
            }
            .mask {
                // One gradient over the whole row (strips side by side left
                // a hairline seam at rest, R1-3): opaque at the leading edge
                // until the row is scrolled; the trailing fade is wide enough
                // that a key cut at rest reads as fading, not as half a key (R1-4).
                GeometryReader { proxy in
                    let width = max(1, proxy.size.width)
                    let lead = edges.fadesLeading ? KeyBarScrollEdges.fade / width : 0
                    let fadesTrailing = scrolling && edges.fadesTrailing
                    let trail = fadesTrailing ? KeyBarScrollEdges.trailingFade / width : 0
                    LinearGradient(stops: [
                        .init(color: edges.fadesLeading ? .clear : .black, location: 0),
                        .init(color: .black, location: lead),
                        .init(color: .black, location: 1 - trail),
                        .init(color: fadesTrailing ? .clear : .black, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("More keys")
            .accessibilityActions {
                ForEach(KeyBarKey.middle.filter { clipped.contains($0) }, id: \.self) { key in
                    Button(key.accessibilityLabel) { model.keyBar(key) }
                }
            }
            Joystick(engine: model.joystickEngine)
            Button {
                model.keyBar(.hideKeyboard)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(Color(uiColor: CnxGhosttyApp.background).opacity(0.85), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 6)
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
                .foregroundStyle(locked || armed ? Color.white : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed))
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(locked ? "locked" : armed ? "armed" : "")
        .accessibilityIdentifier("terminal.key.\(key.identifier)")
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
                // Armed: accent fill, white label. Locked: the same plus a
                // 2 pt underline (SPEC M1). Rest: the quiet fill.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(locked || armed ? AnyShapeStyle(Color(uiColor: .systemBlue).opacity(configuration.isPressed ? 0.8 : 1))
                          : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.08)))
            )
            .overlay(alignment: .bottom) {
                if locked {
                    Capsule().fill(Color.white).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 3)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(.rect)
    }
}
#endif
