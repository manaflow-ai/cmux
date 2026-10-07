/// One file's patch in the changes screen.
public enum PatchState: Hashable, Sendable {
    case loading
    case loaded(DiffDocument)
    case failed(ViewerSourceError)
}
