// Apart from direct.ts so the pane's early handshake (earlyHandshake.ts) sends them before the pane's
// modules load.
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
    _meta: { acpmux: { peerRowBatches: true } },
  };
}
