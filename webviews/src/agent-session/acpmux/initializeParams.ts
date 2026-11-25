// The page's `initialize` params, in a module of its own that imports nothing: the boot script
// (chatSnapshot/earlyOpen.ts) hands them to the host's `transport.open`, which sends the
// initialize while the bundle still loads, and the bundle's own initialize (direct.ts) must carry
// the same params to take that answer (AcpmuxRequestIds.swift `adoptEarlyInitialize`).

/// The page's `initialize` params. The app's relay checks them against its params rule
/// (AcpmuxPaneMethods+Params.swift `knownParams`), and `schemas/agent-pane/initialize-params.json`
/// holds both sides to the same keys: a key the rule does not know refuses every connection.
export function initializeParams() {
  return {
    protocolVersion: 1,
    clientInfo: { name: "cmux-react-agent-pane", version: "1" },
    clientCapabilities: {},
    // A peer's list comes as one `_acpmux/peer_rows_changed`, read by the next follow
    // (`SessionPager.peerRowsChanged`); an acpmux before it ignores the key and sends each row.
    // `chunkDeltas`: a streamed chunk after the first as `_acpmux/chunk`; `sessionChangedDelta`: a
    // row change after the first as `_acpmux/session_patch`. `receive` reads both back into the
    // frames they stand for (chatDeltas.ts); an acpmux before them ignores the keys.
    _meta: { acpmux: { peerRowBatches: true, chunkDeltas: true, sessionChangedDelta: true } },
  };
}
