import CmuxMobileWire
import CmuxiOSViewersCore
import Foundation

/// Localized strings of the viewers (en, ja).
enum ViewersText {
    // Entry
    static var changes: String { String(localized: "viewers.changes", defaultValue: "Changes", bundle: .module) }

    // Changes
    static var scope: String { String(localized: "viewers.scope", defaultValue: "Compare", bundle: .module) }
    static func scopeName(_ scope: GitDiffScope) -> String {
        switch scope {
        case .uncommitted: String(localized: "viewers.scope.uncommitted", defaultValue: "Uncommitted", bundle: .module)
        case .unstaged: String(localized: "viewers.scope.unstaged", defaultValue: "Unstaged", bundle: .module)
        case .staged: String(localized: "viewers.scope.staged", defaultValue: "Staged", bundle: .module)
        case .committed: String(localized: "viewers.scope.committed", defaultValue: "Last Commit", bundle: .module)
        case .branch: String(localized: "viewers.scope.branch", defaultValue: "Branch", bundle: .module)
        }
    }
    static var showTree: String { String(localized: "viewers.tree", defaultValue: "Show as Tree", bundle: .module) }
    static var refresh: String { String(localized: "viewers.refresh", defaultValue: "Refresh", bundle: .module) }
    static var detached: String { String(localized: "viewers.detached", defaultValue: "Detached HEAD", bundle: .module) }
    static func aheadBehind(_ ahead: Int, _ behind: Int) -> String {
        String(localized: "viewers.ahead-behind", defaultValue: "\(ahead) ahead, \(behind) behind", bundle: .module)
    }
    static func comparedWith(_ base: String) -> String {
        String(localized: "viewers.compared-with", defaultValue: "Compared with \(base)", bundle: .module)
    }
    static func fileCount(_ count: Int) -> String {
        String(localized: "viewers.file-count", defaultValue: "\(count) files", bundle: .module)
    }
    static func omitted(_ count: Int) -> String {
        String(localized: "viewers.omitted", defaultValue: "\(count) more files not shown", bundle: .module)
    }
    static func additionsDeletions(_ additions: Int, _ deletions: Int) -> String {
        String(localized: "viewers.additions-deletions", defaultValue: "\(additions) added, \(deletions) removed", bundle: .module)
    }
    static func renamedFrom(_ path: String) -> String {
        String(localized: "viewers.renamed-from", defaultValue: "Renamed from \(path)", bundle: .module)
    }
    static func status(_ status: GitChangeStatus) -> String {
        switch status {
        case .added: String(localized: "viewers.status.added", defaultValue: "Added", bundle: .module)
        case .modified: String(localized: "viewers.status.modified", defaultValue: "Modified", bundle: .module)
        case .deleted: String(localized: "viewers.status.deleted", defaultValue: "Deleted", bundle: .module)
        case .renamed: String(localized: "viewers.status.renamed", defaultValue: "Renamed", bundle: .module)
        case .untracked: String(localized: "viewers.status.untracked", defaultValue: "Untracked", bundle: .module)
        }
    }
    static var noChanges: String { String(localized: "viewers.no-changes", defaultValue: "No Changes", bundle: .module) }
    static var noChangesBody: String {
        String(localized: "viewers.no-changes.body", defaultValue: "The working tree matches this comparison.", bundle: .module)
    }

    // Diff
    static var unified: String { String(localized: "viewers.layout.unified", defaultValue: "Unified", bundle: .module) }
    static var split: String { String(localized: "viewers.layout.split", defaultValue: "Side by Side", bundle: .module) }
    static var previousHunk: String { String(localized: "viewers.hunk.previous", defaultValue: "Previous Change", bundle: .module) }
    static var nextHunk: String { String(localized: "viewers.hunk.next", defaultValue: "Next Change", bundle: .module) }
    static var openFile: String { String(localized: "viewers.open-file", defaultValue: "Open File", bundle: .module) }
    static var binaryFile: String { String(localized: "viewers.binary", defaultValue: "Binary File", bundle: .module) }
    static var binaryBody: String {
        String(localized: "viewers.binary.body", defaultValue: "This file has no text diff.", bundle: .module)
    }
    static var noTextChanges: String {
        String(localized: "viewers.no-text-changes", defaultValue: "No text changes (renamed or mode only).", bundle: .module)
    }
    static var truncated: String {
        String(localized: "viewers.truncated", defaultValue: "This diff is too large to show in full.", bundle: .module)
    }
    static func hunkLabel(_ index: Int, _ count: Int) -> String {
        String(localized: "viewers.hunk.label", defaultValue: "Change \(index) of \(count)", bundle: .module)
    }
    static func addedLine(_ number: Int, _ text: String) -> String {
        String(localized: "viewers.a11y.added", defaultValue: "Added line \(number): \(text)", bundle: .module)
    }
    static func removedLine(_ number: Int, _ text: String) -> String {
        String(localized: "viewers.a11y.removed", defaultValue: "Removed line \(number): \(text)", bundle: .module)
    }
    static func contextLine(_ number: Int, _ text: String) -> String {
        String(localized: "viewers.a11y.context", defaultValue: "Line \(number): \(text)", bundle: .module)
    }
    static var noNewline: String { String(localized: "viewers.no-newline", defaultValue: "No newline at end of file", bundle: .module) }
    static var emptySide: String { String(localized: "viewers.a11y.empty-side", defaultValue: "No line", bundle: .module) }

    // Viewers
    static var source: String { String(localized: "viewers.source", defaultValue: "Show Source", bundle: .module) }
    static var rendered: String { String(localized: "viewers.rendered", defaultValue: "Show Rendered", bundle: .module) }
    static var share: String { String(localized: "viewers.share", defaultValue: "Share", bundle: .module) }
    static var find: String { String(localized: "viewers.find", defaultValue: "Find", bundle: .module) }
    static var downloading: String { String(localized: "viewers.downloading", defaultValue: "Downloading…", bundle: .module) }
    static var highlightingSkipped: String {
        String(localized: "viewers.highlight-skipped", defaultValue: "Large file: shown without colors.", bundle: .module)
    }
    static func taskProgress(_ done: Int, _ total: Int) -> String {
        String(localized: "viewers.task-progress", defaultValue: "\(done) of \(total) tasks done", bundle: .module)
    }

    // Browser
    static var emptyFolder: String { String(localized: "viewers.empty-folder", defaultValue: "Empty Folder", bundle: .module) }
    static var symlink: String { String(localized: "viewers.symlink", defaultValue: "Link (not followed)", bundle: .module) }

    // Errors
    static var retry: String { String(localized: "viewers.retry", defaultValue: "Try Again", bundle: .module) }
    static func errorTitle(_ error: ViewerSourceError) -> String {
        switch error {
        case .noConnection: String(localized: "viewers.error.connection", defaultValue: "No Connection to This Mac", bundle: .module)
        case .noWorkspaceFolder: String(localized: "viewers.error.folder", defaultValue: "No Shared Folder", bundle: .module)
        case .notARepository: String(localized: "viewers.error.repo", defaultValue: "Not a Git Repository", bundle: .module)
        case .forbidden: String(localized: "viewers.error.forbidden", defaultValue: "Not Shared", bundle: .module)
        case .notFound: String(localized: "viewers.error.not-found", defaultValue: "Not Found", bundle: .module)
        case .tooLarge: String(localized: "viewers.error.too-large", defaultValue: "Too Large", bundle: .module)
        case .needsDirectConnection: String(localized: "viewers.error.direct", defaultValue: "Needs a Direct Connection", bundle: .module)
        case .failed: String(localized: "viewers.error.failed", defaultValue: "Couldn’t Load", bundle: .module)
        }
    }
    static func errorBody(_ error: ViewerSourceError) -> String {
        switch error {
        case .noConnection:
            String(localized: "viewers.error.connection.body", defaultValue: "Open cmux on the Mac and make sure it is online.", bundle: .module)
        case .noWorkspaceFolder:
            String(localized: "viewers.error.folder.body", defaultValue: "This workspace has no folder the Mac shares with your phone.", bundle: .module)
        case .notARepository:
            String(localized: "viewers.error.repo.body", defaultValue: "The workspace folder is not inside a Git repository.", bundle: .module)
        case .forbidden:
            String(localized: "viewers.error.forbidden.body", defaultValue: "The Mac does not share this location with phones.", bundle: .module)
        case .notFound:
            String(localized: "viewers.error.not-found.body", defaultValue: "It may have been moved or deleted on the Mac.", bundle: .module)
        case .tooLarge:
            String(localized: "viewers.error.too-large.body", defaultValue: "The file is larger than the phone can download.", bundle: .module)
        case .needsDirectConnection:
            String(localized: "viewers.error.direct.body", defaultValue: "Files need a direct or peer-to-peer connection to the Mac.", bundle: .module)
        case .failed(let message): message
        }
    }
}
