// The MCP connect card's host ops (`cmux.home.mcp.*`), for the swap PR to wire on the
// `home-messages` page route. Each effect of a flow step (mcpConnect.ts) is one op, sent on the
// person's own connection; the host forwards it to the acpmux daemon and streams the daemon's
// answers back as `cmux.home.mcp.state` events, which step the flow (`signedIn`, `connected`,
// `failed`). A key goes out once, in `submitKey`, and is never in an event or a log.
import type { McpEffect, McpScope, McpTool } from "./mcpConnect";

export const MCP_OPS = {
  /** `{requestID, approve: true, scope}` or `{requestID, approve: false}`: `_acpmux/mcp_connect_answer`. */
  answer: "cmux.home.mcp.answer",
  /** `{requestID, key}`: `_acpmux/mcp_key_submit`. The key goes to the daemon only. */
  submitKey: "cmux.home.mcp.submitKey",
  /** `{requestID}`: `_acpmux/mcp_auth_begin`; the host opens the URL it returns in a cmux browser tab. */
  beginSignIn: "cmux.home.mcp.beginSignIn",
} as const;

/** The event the host sends with the daemon's answers for one card. */
export const MCP_STATE_EVENT = "cmux.home.mcp.state";

/** One daemon answer for card `requestID`. */
export type McpStateEvent =
  | { requestID: string; kind: "signedIn" }
  | { requestID: string; kind: "connected"; tools: McpTool[] }
  | { requestID: string; kind: "failed"; reason: string };

export type McpAnswerParams =
  | { requestID: string; approve: true; scope: McpScope }
  | { requestID: string; approve: false };

export type HostCall = (op: string, params: Record<string, unknown>) => Promise<unknown>;

/** Sends a step's effects, in order, as host ops. */
export async function sendMcpEffects(call: HostCall, requestID: string, effects: readonly McpEffect[]): Promise<void> {
  for (const effect of effects) {
    switch (effect.kind) {
      case "approve":
        await call(MCP_OPS.answer, { requestID, approve: true, scope: effect.scope });
        break;
      case "decline":
        await call(MCP_OPS.answer, { requestID, approve: false });
        break;
      case "submitKey":
        await call(MCP_OPS.submitKey, { requestID, key: effect.key.reveal() });
        break;
      case "beginSignIn":
        await call(MCP_OPS.beginSignIn, { requestID });
        break;
    }
  }
}
