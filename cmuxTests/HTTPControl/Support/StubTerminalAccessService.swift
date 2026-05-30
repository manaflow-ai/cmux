import CmuxTerminalAccess
import Foundation

/// In-memory stub used by HTTPControl route tests.
///
/// Implements the ``TerminalAccessService`` protocol with simple stored
/// state so tests can pre-seed surfaces, screen-read results, and
/// inspect the last write request without spinning up a real
/// ``DefaultTerminalAccessService`` + provider.
///
/// Per Errata E17 every protocol method is `async throws`; the stub
/// never throws on success but the keyword still has to be present to
/// match the protocol signature.
final actor StubTerminalAccessService: TerminalAccessService {
    private var surfaces: [SurfaceInfo] = []
    private var screenResult: ScreenReadResult?
    private(set) var lastInput: InputRequest?

    init() {}

    func setSurfaces(_ s: [SurfaceInfo]) { self.surfaces = s }
    func setScreen(_ r: ScreenReadResult?) { self.screenResult = r }

    func listSurfaces() async throws -> [SurfaceInfo] { surfaces }

    func readScreen(_ req: ScreenReadRequest) async throws -> ScreenReadResult {
        guard surfaces.contains(where: { $0.handle == req.handle }) else {
            throw TerminalAccessError.unknownSurface
        }
        return screenResult ?? .text(
            TextScreenPayload(
                cols: 80,
                rows: 24,
                altScreen: false,
                title: nil,
                text: "stub"
            )
        )
    }

    func writeInput(_ req: InputRequest) async throws {
        guard surfaces.contains(where: { $0.handle == req.handle }) else {
            throw TerminalAccessError.unknownSurface
        }
        lastInput = req
    }
}
