import Foundation
import Darwin

struct SessionIndexSyntheticCorpus: Sendable {
    let homeDirectory: URL
    let projectsDirectory: URL
    let transcriptCount: Int

    @concurrent
    static func create(projectCount: Int, transcriptsPerProject: Int) async throws -> Self {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-vault-corpus-\(UUID().uuidString)", isDirectory: true)
        let projectsDirectory = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)

        for projectIndex in 0..<projectCount {
            let projectDirectory = projectsDirectory
                .appendingPathComponent("-tmp-project-\(projectIndex)", isDirectory: true)
            try fileManager.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            for transcriptIndex in 0..<transcriptsPerProject {
                let sessionID = "session-\(projectIndex)-\(transcriptIndex)"
                let line = """
                {"type":"user","sessionId":"\(sessionID)","cwd":"/tmp/project-\(projectIndex)","message":{"role":"user","content":"Synthetic transcript \(transcriptIndex)"}}

                """
                try Data(line.utf8).write(
                    to: projectDirectory.appendingPathComponent("\(sessionID).jsonl")
                )
            }
        }

        return Self(
            homeDirectory: homeDirectory,
            projectsDirectory: projectsDirectory,
            transcriptCount: projectCount * transcriptsPerProject
        )
    }

    func loadEntries() -> [SessionEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let executorLabel = pthread_main_np() == 0 ? "off-main" : "main"
        var entries: [SessionEntry] = []
        entries.reserveCapacity(transcriptCount)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty else {
                continue
            }
            let sessionID = url.deletingPathExtension().lastPathComponent
            entries.append(SessionEntry(
                id: "claude:\(url.path)",
                agent: .claude,
                sessionId: sessionID,
                title: executorLabel,
                cwd: url.deletingLastPathComponent().lastPathComponent,
                gitBranch: nil,
                pullRequest: nil,
                modified: values.contentModificationDate ?? .distantPast,
                fileURL: url,
                specifics: .claude(
                    model: nil,
                    permissionMode: nil,
                    configDirectoryForResume: nil
                )
            ))
        }
        return entries
    }

    @concurrent
    func remove() async {
        try? FileManager.default.removeItem(at: homeDirectory)
    }
}
