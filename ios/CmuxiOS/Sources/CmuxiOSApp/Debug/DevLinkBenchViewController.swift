#if DEBUG
import CmuxLinkBench
import CmuxLinkDirect
import Foundation
import UIKit

/// A small, injectable DEV surface for running the split Mac/iOS link bench.
///
/// The Mac `cmux-link-bench serve` command writes a JSON descriptor. Paste that
/// descriptor into this screen (or provide `CMUX_IOS_LINK_BENCH_DESCRIPTOR` at
/// launch), then tap Run. The default identity is intentionally ephemeral so
/// this screen works with the server's explicit `--allow-any` mode; a paired
/// device can inject its Keychain-backed ``DirectIdentity`` at construction.
@MainActor
final class DevLinkBenchViewController: UIViewController {
    typealias Runner = @Sendable (
        _ descriptor: BenchServeDescriptor,
        _ identity: DirectIdentity,
        _ quick: Bool,
        _ progress: @escaping @Sendable (String) -> Void
    ) async throws -> BenchReport

    private let identity: DirectIdentity
    private let runner: Runner
    private let descriptorEditor = UITextView()
    private let resultView = UITextView()
    private let statusLabel = UILabel()
    private let quickSwitch = UISwitch()
    private let runButton = UIButton(type: .system)
    private var runTask: Task<Void, Never>?
    private var reportPersistenceError: String?
    /// The completed report as UTF-8 JSON, for DEV capture or tests.
    private(set) var reportData: Data?
    /// Called after a report is encoded. The default factory writes a cache
    /// artifact; callers can replace it with a test or upload sink.
    var onReport: ((Data) -> Void)?
    /// Called before a new run starts so the default sink can remove stale
    /// artifacts left by an earlier run.
    var onRunStart: (() -> Void)?

    static func make() -> DevLinkBenchViewController {
        let controller = DevLinkBenchViewController()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery", isDirectory: true)
        controller.onRunStart = {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { return }
            for file in files where
                (file.lastPathComponent == "link-bench.json" || file.lastPathComponent.hasPrefix("link-bench-")) &&
                file.pathExtension == "json"
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
        controller.onReport = { data in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let report = try JSONDecoder().decode(BenchReport.self, from: data)
                guard let runID = report.provenance?.runID, !runID.isEmpty else {
                    throw BenchSplitError.server("benchmark report has no build provenance")
                }
                let safeID = runID.replacingOccurrences(
                    of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
                )
                try data.write(to: directory.appendingPathComponent("link-bench-\(safeID).json"), options: .atomic)
            } catch {
                controller.reportPersistenceError = error.localizedDescription
            }
        }
        return controller
    }

    init(identity: DirectIdentity = DirectIdentity(), descriptorData: Data? = nil, runner: Runner? = nil) {
        self.identity = identity
        self.runner = runner ?? Self.liveRunner
        super.init(nibName: nil, bundle: nil)
        if let descriptorData {
            descriptorEditor.text = String(decoding: descriptorData, as: UTF8.self)
        } else if let text = ProcessInfo.processInfo.environment["CMUX_IOS_LINK_BENCH_DESCRIPTOR"] {
            descriptorEditor.text = text
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Link benchmark"
        view.backgroundColor = .systemBackground

        let descriptorLabel = UILabel()
        descriptorLabel.text = "Mac descriptor JSON"
        descriptorLabel.font = .preferredFont(forTextStyle: .headline)

        descriptorEditor.translatesAutoresizingMaskIntoConstraints = false
        descriptorEditor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        descriptorEditor.layer.borderColor = UIColor.separator.cgColor
        descriptorEditor.layer.borderWidth = 1
        descriptorEditor.layer.cornerRadius = 8
        descriptorEditor.autocorrectionType = .no
        descriptorEditor.autocapitalizationType = .none
        descriptorEditor.accessibilityIdentifier = "link.bench.descriptor"
        descriptorEditor.text = descriptorEditor.text.isEmpty
            ? "Paste cmux-link-bench-serve/1 JSON here"
            : descriptorEditor.text

        let quickLabel = UILabel()
        quickLabel.text = "Quick run"
        quickLabel.font = .preferredFont(forTextStyle: .body)
        quickSwitch.isOn = true
        quickSwitch.accessibilityIdentifier = "link.bench.quick"

        runButton.setTitle("Run", for: .normal)
        runButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)
        runButton.accessibilityIdentifier = "link.bench.run"

        statusLabel.text = "Paste a descriptor to begin."
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "link.bench.status"

        resultView.translatesAutoresizingMaskIntoConstraints = false
        resultView.isEditable = false
        resultView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultView.layer.borderColor = UIColor.separator.cgColor
        resultView.layer.borderWidth = 1
        resultView.layer.cornerRadius = 8
        resultView.accessibilityIdentifier = "link.bench.result"

        let options = UIStackView(arrangedSubviews: [quickLabel, quickSwitch, runButton])
        options.axis = .horizontal
        options.spacing = 12
        options.alignment = .center

        let stack = UIStackView(arrangedSubviews: [descriptorLabel, descriptorEditor, options, statusLabel, resultView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            descriptorEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            resultView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        runTask?.cancel()
        runTask = nil
        runButton.isEnabled = true
    }

    @objc private func runTapped() {
        guard runTask == nil else { return }
        let data = Data(descriptorEditor.text.utf8)
        let descriptor: BenchServeDescriptor
        do {
            descriptor = try BenchServeDescriptor.decode(data)
        } catch {
            statusLabel.text = "Descriptor error: \(error.localizedDescription)"
            return
        }

        runButton.isEnabled = false
        reportData = nil
        onRunStart?()
        resultView.text = ""
        statusLabel.text = "Connecting to \(descriptor.address):\(descriptor.port)…"
        let runner = self.runner
        let identity = self.identity
        let quick = quickSwitch.isOn
        runTask = Task { [weak self] in
            do {
                let report = try await runner(descriptor, identity, quick) { line in
                    Task { @MainActor [weak self] in self?.statusLabel.text = line }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.reportData = data
                self.reportPersistenceError = nil
                self.onReport?(data)
                self.resultView.text = String(decoding: data, as: UTF8.self)
                if let error = self.reportPersistenceError {
                    self.statusLabel.text = "Could not save report: \(error)"
                } else {
                    self.statusLabel.text = report.errors.isEmpty ? "Completed." : "Completed with errors."
                }
                self.runTask = nil
                self.runButton.isEnabled = true
            } catch is CancellationError {
                self?.statusLabel.text = "Cancelled."
                self?.runTask = nil
                self?.runButton.isEnabled = true
            } catch {
                self?.statusLabel.text = "Benchmark failed: \(error.localizedDescription)"
                self?.runTask = nil
                self?.runButton.isEnabled = true
            }
        }
    }

    private static let liveRunner: Runner = { descriptor, identity, quick, progress in
        let client = try BenchSplitClient(descriptor: descriptor, deviceIdentity: identity)
        var spec = BenchSpec(rig: .v3, quick: quick)
        spec.bulkRecordBytes = descriptor.bulkRecordBytes
        let info = Bundle.main.infoDictionary ?? [:]
        func bundleString(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
            return value
        }
        func sourceSHA(_ value: String?) -> String? {
            guard let value, (7...40).contains(value.count),
                  value.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (65...70).contains(scalar.value) ||
                      (97...102).contains(scalar.value)
                  }) else { return nil }
            return value
        }
        guard let sourceGitSHA = sourceSHA(bundleString("CMUXGitSHA")),
              let devTag = bundleString("CMUXDevTag"),
              let buildNumber = bundleString("CFBundleVersion") else {
            throw BenchSplitError.server("app bundle has no exact build provenance")
        }
        return try await client.run(
            spec: spec,
            provenance: BenchReportProvenance(
                sourceGitSHA: sourceGitSHA, devTag: devTag, buildNumber: buildNumber
            ),
            progress: progress
        )
    }
}
#endif
