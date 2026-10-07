/// Opens a result through the owner's navigator or the shell router.
@MainActor
public protocol SearchOpening: AnyObject {
    func open(_ destination: SearchDestination)
}
