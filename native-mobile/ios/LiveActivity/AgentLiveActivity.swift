import ActivityKit
import SwiftUI
import WidgetKit

/// An agent run on the Mac: lock screen banner and Dynamic Island, in
/// cmux-next's ink and gray. The only color is the attention orange when
/// the agent needs input (and a quiet green check when it is done).
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.ink)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        AgentGlyph(state: context.state.state, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.agent)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text(context.attributes.workspace.isEmpty ? String(localized: "Mac") : context.attributes.workspace)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        StatePill(state: context.state.state, detail: context.state.detail)
                        Spacer()
                        if context.state.state == .needsInput {
                            Text(String(localized: "Open to answer"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                }
            } compactLeading: {
                AgentGlyph(state: context.state.state, size: 22)
            } compactTrailing: {
                switch context.state.state {
                case .working:
                    ElapsedText(state: context.state)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: 46)
                case .needsInput:
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Palette.attention)
                case .done:
                    Image(systemName: "checkmark").foregroundStyle(Palette.success)
                }
            } minimal: {
                AgentGlyph(state: context.state.state, size: 22)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(context.state.state == .needsInput ? Palette.attention : Palette.secondary)
        }
    }
}

private enum Palette {
    static let background = Color(white: 0.07).opacity(0.92)
    static let ink = Color.white
    static let secondary = Color(white: 0.62)
    static let tertiary = Color(white: 0.32)
    static let attention = Color(red: 0.98, green: 0.62, blue: 0.24)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.47)
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentGlyph(state: context.state.state, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.agent)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(context.attributes.workspace.isEmpty ? String(localized: "On your Mac") : context.attributes.workspace)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ElapsedText(state: context.state)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            HStack {
                StatePill(state: context.state.state, detail: context.state.detail)
                Spacer()
                Text("cmux")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(16)
    }
}

/// A terminal glyph in a rounded square; the ring shows the state.
private struct AgentGlyph: View {
    let state: AgentActivityAttributes.ContentState.State
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(white: 0.16))
            Image(systemName: "chevron.forward")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Palette.ink)
                .offset(x: -size * 0.1)
            Rectangle()
                .fill(Palette.ink)
                .frame(width: size * 0.22, height: size * 0.07)
                .offset(x: size * 0.16, y: size * 0.13)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(ringColor, lineWidth: state == .working ? 1 : 2)
        )
    }

    private var ringColor: Color {
        switch state {
        case .working: Palette.tertiary
        case .needsInput: Palette.attention
        case .done: Palette.success
        }
    }
}

private struct StatePill: View {
    let state: AgentActivityAttributes.ContentState.State
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .working:
                Circle().fill(Palette.secondary).frame(width: 6, height: 6)
            case .needsInput:
                Circle().fill(Palette.attention).frame(width: 6, height: 6)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.success)
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state == .needsInput ? Palette.attention : Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(white: 0.16)))
    }

    private var label: String {
        if !detail.isEmpty, state != .working { return detail }
        switch state {
        case .working: return String(localized: "Working")
        case .needsInput: return String(localized: "Needs your input")
        case .done: return String(localized: "Done")
        }
    }
}

/// Elapsed time since the run started, ticking while it works.
private struct ElapsedText: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if state.state == .done {
            Text(String(localized: "Done"))
        } else {
            Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
        }
    }
}
