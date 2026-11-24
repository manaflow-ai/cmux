// The page's `initialize`, apart from the client so the page can send it before the client loads
// (earlyConnect.ts).

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

/// The id of an `initialize` the page sent before its first client held the socket (earlyConnect.ts):
/// the client's own ids start at 1, so its replies never meet this one.
export const EARLY_INITIALIZE_ID = 0;
