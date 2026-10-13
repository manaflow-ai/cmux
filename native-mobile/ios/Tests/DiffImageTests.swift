import Testing
@testable import CmuxNative

struct DiffImageSourceTests {
    private func file(_ status: DiffFile.Status, path: String = "img/logo.png", old: String? = nil) -> DiffFile {
        DiffFile(index: 0, path: path, oldPath: old, status: status, isBinary: true)
    }

    @Test func workingTreeComparesIndexToDisk() {
        let plan = DiffImageSource.plan(file(.modified), scope: .workingTree)
        #expect(plan.old == .git(path: "img/logo.png", rev: nil))
        #expect(plan.new == .disk(path: "img/logo.png"))
    }

    @Test func stagedComparesHeadToIndex() {
        let plan = DiffImageSource.plan(file(.modified), scope: .staged)
        #expect(plan.old == .git(path: "img/logo.png", rev: "HEAD"))
        #expect(plan.new == .git(path: "img/logo.png", rev: nil))
    }

    @Test func baseComparesTheRefToDisk() {
        let plan = DiffImageSource.plan(file(.modified), scope: .base("main"))
        #expect(plan.old == .git(path: "img/logo.png", rev: "main"))
        #expect(plan.new == .disk(path: "img/logo.png"))
    }

    @Test func addedHasNoOldSideAndDeletedNoNewSide() {
        #expect(DiffImageSource.plan(file(.added), scope: .workingTree).old == nil)
        #expect(DiffImageSource.plan(file(.deleted), scope: .workingTree).new == nil)
    }

    @Test func renameReadsTheOldPath() {
        let plan = DiffImageSource.plan(file(.renamed, path: "new.png", old: "old.png"), scope: .staged)
        #expect(plan.old == .git(path: "old.png", rev: "HEAD"))
        #expect(plan.new == .git(path: "new.png", rev: nil))
    }

    @Test func onlyBinaryImagesGetAPreview() {
        #expect(DiffImageSource.isPreviewable(file(.modified)))
        #expect(!DiffImageSource.isPreviewable(file(.modified, path: "a.bin")))
        var text = file(.modified); text.isBinary = false
        #expect(!DiffImageSource.isPreviewable(text))
    }
}
