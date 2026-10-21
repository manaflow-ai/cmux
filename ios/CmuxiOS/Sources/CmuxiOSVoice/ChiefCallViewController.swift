public import CmuxChiefVoiceCore
import Observation
public import UIKit

/// The full-screen Chief call: who, how long, what is happening, and End.
///
/// Renders ``ChiefCallCoordinator/state`` (re-registered observation, no
/// polling) and forwards End to the coordinator. Done appears once the note is
/// sent or saved; `onDone` dismisses the screen. HIG pages checked:
/// "Playing audio", "Buttons", "Modality" (full screen for a focused task).
@MainActor
public final class ChiefCallViewController: UIViewController {
    private let coordinator: ChiefCallCoordinator
    private let chiefName: String
    private let mode: ChiefVoiceRequest
    /// Called when the user taps Done or Open Settings; the presenter dismisses.
    public var onDone: (() -> Void)?

    private let monogram = UILabel()
    private let titleLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let statusLabel = UILabel()
    private let endButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var clock: Task<Void, Never>?

    /// Creates the screen.
    /// - Parameters:
    ///   - coordinator: The call flow to show and drive.
    ///   - chiefName: The Chief's display name for the title (nil: "Chief").
    ///   - mode: Call or voice note, for the title.
    public init(coordinator: ChiefCallCoordinator, chiefName: String?, mode: ChiefVoiceRequest) {
        self.coordinator = coordinator
        self.chiefName = chiefName.flatMap { $0.isEmpty ? nil : $0 } ?? VoiceText.callTitle
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        monogram.text = String(chiefName.prefix(1)).uppercased()
        monogram.font = .systemFont(ofSize: 44, weight: .semibold)
        monogram.textAlignment = .center
        monogram.textColor = .label
        monogram.backgroundColor = .secondarySystemBackground
        monogram.layer.cornerRadius = 56
        monogram.clipsToBounds = true
        monogram.isAccessibilityElement = false

        titleLabel.text = mode == .call ? chiefName : VoiceText.voiceNoteTitle
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.textAlignment = .center

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        var end = UIButton.Configuration.filled()
        end.image = UIImage(systemName: "phone.down.fill")
        end.baseBackgroundColor = .systemRed
        end.baseForegroundColor = .white
        end.cornerStyle = .capsule
        end.contentInsets = NSDirectionalEdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
        endButton.configuration = end
        endButton.accessibilityLabel = VoiceText.endButton
        endButton.addAction(UIAction { [weak self] _ in self?.endTapped() }, for: .primaryActionTriggered)

        var done = UIButton.Configuration.borderedProminent()
        done.title = VoiceText.doneButton
        done.cornerStyle = .capsule
        done.baseBackgroundColor = .label
        done.baseForegroundColor = .systemBackground
        doneButton.configuration = done
        doneButton.addAction(UIAction { [weak self] _ in self?.doneTapped() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [monogram, titleLabel, elapsedLabel, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: monogram)
        stack.translatesAutoresizingMaskIntoConstraints = false
        endButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(endButton)
        view.addSubview(doneButton)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            monogram.widthAnchor.constraint(equalToConstant: 112),
            monogram.heightAnchor.constraint(equalToConstant: 112),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 72),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            endButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -48),
            doneButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            doneButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -48),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        render()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.cancel()
        clock = nil
    }

    private func endTapped() {
        Task { await coordinator.end() }
    }

    private func doneTapped() {
        if coordinator.state == .permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        onDone?()
    }

    /// Draws the current state, then re-registers for the next change.
    private func render() {
        let state = withObservationTracking { coordinator.state } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        let status: String
        var recordingSince: Date?
        var finished = false
        switch state {
        case .idle, .requestingPermission: status = VoiceText.askingMicrophone
        case .permissionDenied: status = VoiceText.microphoneDenied; finished = true
        case .recording(_, let startedAt): status = VoiceText.recording; recordingSince = startedAt
        case .finishing: status = VoiceText.saving
        case .transcribing: status = VoiceText.transcribing
        case .sending: status = VoiceText.sending
        case .sent: status = VoiceText.sent; finished = true
        case .savedForLater: status = VoiceText.savedForLater; finished = true
        case .failed: status = VoiceText.failed; finished = true
        }
        if statusLabel.text != status {
            statusLabel.text = status
            UIAccessibility.post(notification: .announcement, argument: status)
        }
        endButton.isHidden = recordingSince == nil
        doneButton.isHidden = !finished
        var done = doneButton.configuration
        done?.title = state == .permissionDenied ? VoiceText.openSettingsButton : VoiceText.doneButton
        doneButton.configuration = done
        runClock(since: recordingSince)
    }

    /// Ticks the elapsed label once a second while recording.
    private func runClock(since start: Date?) {
        clock?.cancel()
        clock = nil
        guard let start else { return }
        elapsedLabel.text = Self.format(Date().timeIntervalSince(start))
        clock = Task { [weak self] in
            while !Task.isCancelled {
                // Clock.sleep carve-out: display cadence for the elapsed clock, a
                // bounded delay cancelled by render() on every state change; not a state poll.
                try? await ContinuousClock().sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.elapsedLabel.text = Self.format(Date().timeIntervalSince(start))
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}
