public import CmuxTerminalRenderCore
import Foundation
import os
import QuartzCore
public import UIKit

/// DEV screen: replays a workload (corpus case, flood, htop, vim) through the
/// real renderer and reports frame timing. Every presented frame is an
/// `os_signpost` interval (subsystem `dev.cmux.ios`, category `terminal`,
/// name `frame`), and each run is a `workload` interval, so Instruments
/// shows the same numbers. DEBUG builds write `terminal-bench.json` next to
/// the simulator gallery.
@MainActor
public final class TerminalBenchViewController: UIViewController {
    public private(set) var workload: TerminalWorkload
    private let source = FixtureByteSource()
    private let session: TerminalSession
    private let summary = UILabel()
    private let generator = TerminalWorkloadGenerator()
    private let corpus = TerminalCorpusBundle()
    private var stats = FrameTimingStats()
    private var totalBytes = 0
    private var finishedDelivery = false
    private var reported = false
    private let signposter = OSSignposter(subsystem: "dev.cmux.ios", category: "terminal")
    private var frameInterval: OSSignpostIntervalState?
    private var workloadInterval: OSSignpostIntervalState?
    /// The last run's report (DEV diagnostics).
    public private(set) var report: [String: String] = [:]
    /// A run finished (fleet capture writes the report).
    public var onReport: (([String: String]) -> Void)?

    public init(workload: TerminalWorkload = .flood(bytes: 8 * 1024 * 1024)) {
        self.workload = workload
        session = TerminalSession(source: source, view: GhosttyTerminalView(authority: .local))
        super.init(nibName: nil, bundle: nil)
        title = TerminalText.benchTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let terminal = session.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.numberOfLines = 0
        summary.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        summary.adjustsFontForContentSizeCategory = true
        summary.textColor = .white
        summary.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        summary.accessibilityIdentifier = "terminal.bench.summary"
        view.addSubview(summary)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: summary.topAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summary.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: TerminalText.benchWorkload, menu: workloadMenu())
        terminal.onDraw = { [weak self] in self?.framePresented() }
        session.onParsed = { [weak self] count in self?.parsed(count) }
        source.onFinished = { [weak self] in
            self?.finishedDelivery = true
            self?.finishIfDone()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        run(workload)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stop()
    }

    /// Replays `workload` from the start.
    public func run(_ workload: TerminalWorkload) {
        self.workload = workload
        session.stop()
        let grid = session.view.fittingGrid
        let script: TerminalWorkloadScript? = switch workload {
        case .corpus(let name): corpus.script(named: name, generator: generator)
        default: generator.script(workload, cols: grid.cols, rows: grid.rows)
        }
        guard let script else {
            summary.text = TerminalText.benchUnavailable
            return
        }
        // Start clean: a reset first, so runs do not stack scrollback.
        let replay = TerminalWorkloadScript(name: script.name, cols: script.cols, rows: script.rows,
                                            chunks: [Data("\u{1B}c".utf8)] + script.chunks)
        source.load(replay)
        stats = FrameTimingStats()
        totalBytes = replay.totalBytes
        finishedDelivery = false
        reported = false
        summary.text = String(format: TerminalText.benchRunning, workload.id)
        if let workloadInterval { signposter.endInterval("workload", workloadInterval) }
        workloadInterval = signposter.beginInterval("workload", id: signposter.makeSignpostID(), "\(workload.id, privacy: .public)")
        session.start()
    }

    private func framePresented() {
        let now = CACurrentMediaTime()
        if let frameInterval { signposter.endInterval("frame", frameInterval) }
        frameInterval = nil
        // Frames count only while a run is in progress.
        guard workloadInterval != nil else { return }
        frameInterval = signposter.beginInterval("frame")
        stats.frame(at: now)
    }

    private func parsed(_ count: Int) {
        stats.parsed(count)
        finishIfDone()
    }

    /// Done when every chunk was delivered and parsed.
    private func finishIfDone() {
        guard finishedDelivery, !reported, stats.bytes >= totalBytes else { return }
        reported = true
        if let workloadInterval { signposter.endInterval("workload", workloadInterval) }
        workloadInterval = nil
        let budget = TerminalGestureFrameLink.pacing(for: view.window?.screen).frameBudget
        var report = stats.report(workload: workload.id, budget: budget)
        report["grid"] = "\(session.view.fittingGrid.cols)x\(session.view.fittingGrid.rows)"
        report["display_max_fps"] = String(view.window?.screen.maximumFramesPerSecond ?? 0)
        self.report = report
        summary.text = String(format: TerminalText.benchSummary, workload.id, report["frames"] ?? "", report["p50_ms"] ?? "",
                              report["p99_ms"] ?? "", report["hitches"] ?? "", report["mib_per_s"] ?? "")
        onReport?(report)
    }

    private func workloadMenu() -> UIMenu {
        let generated = TerminalWorkload.generatedDefaults.map { workload in
            UIAction(title: workload.id) { [weak self] _ in self?.run(workload) }
        }
        let cases = corpus.cases.map { entry in
            UIAction(title: entry.name) { [weak self] _ in self?.run(.corpus(entry.name)) }
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: generated),
                                 UIMenu(options: .displayInline, children: cases)])
    }
}
