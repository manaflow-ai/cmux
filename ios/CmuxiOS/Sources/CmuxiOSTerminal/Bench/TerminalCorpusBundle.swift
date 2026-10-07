import CmuxTerminalRenderCore
import Foundation

/// The fidelity-corpus cases bundled for the benchmark (copies of
/// `schemas/terminal-corpus`, drift-checked by CmuxTerminalRenderCore tests).
struct TerminalCorpusBundle {
    let manifest: TerminalCorpusManifest?

    init(bundle: Bundle = .module) {
        manifest = Self.url("manifest.json", in: bundle)
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? TerminalCorpusManifest(decoding: $0) }
        self.bundle = bundle
    }

    private let bundle: Bundle

    /// Cases whose bytes are bundled.
    var cases: [TerminalCorpusManifest.Case] {
        (manifest?.cases ?? []).filter { Self.url($0.file, in: bundle) != nil }
    }

    func script(named name: String, generator: TerminalWorkloadGenerator) -> TerminalWorkloadScript? {
        guard let entry = manifest?.case(named: name), let url = Self.url(entry.file, in: bundle),
              let bytes = try? Data(contentsOf: url) else { return nil }
        return generator.script(corpus: entry, bytes: bytes)
    }

    private static func url(_ file: String, in bundle: Bundle) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "TerminalCorpus")
            ?? bundle.url(forResource: name, withExtension: ext)
    }
}
