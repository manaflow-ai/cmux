#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

/// Self-playing DEBUG fixture for visual and motion verification of mobile toasts.
struct MobileToastShowcaseView: View {
    @Environment(MobileToastPresenter.self) private var toastPresenter
    @State private var replayID = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.cyan)
                        .symbolRenderingMode(.hierarchical)

                    Text(L10n.string(
                        "mobile.toast.showcase.title",
                        defaultValue: "Toast motion"
                    ))
                    .font(.title2.weight(.semibold))

                    Text(L10n.string(
                        "mobile.toast.showcase.subtitle",
                        defaultValue: "A shared edge for brief app feedback."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button {
                        replayID += 1
                    } label: {
                        Label(
                            L10n.string(
                                "mobile.toast.showcase.replay",
                                defaultValue: "Replay sequence"
                            ),
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.cyan)
                    .accessibilityIdentifier("MobileToastShowcaseReplay")
                }
                .padding(30)
            }
            .navigationTitle(L10n.string(
                "mobile.toast.showcase.navigationTitle",
                defaultValue: "Workspace"
            ))
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("MobileToastShowcase")
        .task(id: replayID) {
            await playSequence()
        }
    }

    private func playSequence() async {
        let clock = ContinuousClock()
        do {
            try await clock.sleep(for: .milliseconds(650))
            toastPresenter.present(
                .progress(
                    title: localizedToastText(
                        "mobile.toast.showcase.progress.title",
                        defaultValue: "Syncing workspace"
                    ),
                    message: localizedToastText(
                        "mobile.toast.showcase.progress.message",
                        defaultValue: "Waiting for Mac Studio"
                    ),
                    coalescingKey: "toast-showcase-sync",
                    accessibilityIdentifier: "MobileToastShowcaseProgress"
                )
            )

            try await clock.sleep(for: .milliseconds(1_350))
            toastPresenter.present(
                .success(
                    localizedToastText(
                        "mobile.toast.showcase.success",
                        defaultValue: "Workspace synced"
                    ),
                    coalescingKey: "toast-showcase-sync",
                    accessibilityIdentifier: "MobileToastShowcaseSuccess"
                )
            )

            try await clock.sleep(for: .milliseconds(3_200))
            toastPresenter.present(
                .warning(
                    title: localizedToastText(
                        "mobile.toast.showcase.warning.title",
                        defaultValue: "Mac is busy"
                    ),
                    message: localizedToastText(
                        "mobile.toast.showcase.warning.message",
                        defaultValue: "Another workspace action is still finishing."
                    ),
                    action: MobileToastAction(
                        label: localizedToastText(
                            "mobile.toast.showcase.retry",
                            defaultValue: "Retry"
                        )
                    ) {
                        toastPresenter.present(
                            .information(
                                localizedToastText(
                                    "mobile.toast.showcase.retrying",
                                    defaultValue: "Trying again"
                                ),
                                coalescingKey: "toast-showcase-warning"
                            )
                        )
                    },
                    coalescingKey: "toast-showcase-warning",
                    accessibilityIdentifier: "MobileToastShowcaseWarning"
                )
            )

            try await clock.sleep(for: .milliseconds(2_500))
            toastPresenter.present(
                .error(
                    title: localizedToastText(
                        "mobile.toast.showcase.error.title",
                        defaultValue: "Couldn't rename workspace"
                    ),
                    message: localizedToastText(
                        "mobile.toast.showcase.error.message",
                        defaultValue: "Not connected to Mac Studio."
                    ),
                    coalescingKey: "toast-showcase-error",
                    accessibilityIdentifier: "MobileToastShowcaseError"
                )
            )
        } catch {
            return
        }
    }

    private func localizedToastText(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> MobileToastText {
        .localized(key, defaultValue: defaultValue)
    }
}
#endif
