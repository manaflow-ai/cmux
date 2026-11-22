// The MCP connect card's model and state machine, ported from Swift `McpConnectCard`,
// `McpConnectCardFlow` and `McpConnectKey` (plans/cmux-next/mcp-connect-DESIGN.md sections 3 and 4):
// only the person's steps approve, the scope is theirs, and a key never prints. Pure, so every step
// has a test (mcpConnect.test.ts); the host sends what each step's effects name to the acpmux daemon
// on the person's own connection (mcpHost.ts), the only one whose answer counts.

/** Where the server runs. */
export type McpTransport =
  /** A remote server at this URL. */
  | { kind: "remote"; url: string }
  /** A local stdio server: argv exactly as it runs, its binary's SHA-256, and whether the launcher
   * fetches code at run time (`npx`, `uvx`). */
  | { kind: "local"; argv: readonly string[]; binarySHA256: string; fetchesCode: boolean };

/** How the server signs in. */
export type McpAuth =
  | { kind: "none" }
  /** OAuth 2.1 with PKCE in a cmux browser tab, asking for these scopes. */
  | { kind: "oauth"; scopes: readonly string[] }
  /** A device code the person approves on the service's page. */
  | { kind: "device"; scopes: readonly string[] }
  /** A key typed into the card's private field; `optional` when the server also works without one. */
  | { kind: "key"; name: string; optional: boolean };

/** Who gets the server (design section 2b). Only the person's choice counts. */
export type McpScope = "chat" | "chief" | "allChiefs" | "agents" | "everywhere";
export const MCP_SCOPES: readonly McpScope[] = ["chat", "chief", "allChiefs", "agents", "everywhere"];

/** One tool of a connected server. */
export interface McpTool {
  name: string;
  kind: "read" | "write" | "destructive";
  /** The tool-text screen flagged it: it starts at Never. */
  flagged?: boolean;
}

/** What the card shows: the acpmux `mcp_connect_request` record, as the app gets it. Every fact the
 * person needs to decide is here; a secret never is. */
export interface McpConnectCardData {
  requestID: string;
  /** The agent that asked ("Chief", "a12"). */
  agent: string;
  /** The agent's one sentence: what it will use the server for. */
  reason: string;
  title: string;
  /** The registrable domain shown as "By". */
  publisher: string;
  /** A registry server at its exact URL. */
  verified: boolean;
  /** The host has an international name (shown in punycode). */
  idn?: boolean;
  transport: McpTransport;
  auth: McpAuth;
  proposedScope: McpScope;
  /** Lines the daemon adds (an unverified server, a launcher that downloads code). */
  warnings?: readonly string[];
}

/** The card leads with its risk: an unverified, international-name or local server. */
export function isRisky(card: McpConnectCardData): boolean {
  if (card.transport.kind === "local") return true;
  return !card.verified || card.idn === true;
}

/** The scopes the sign-in asks for (empty for none or a key). */
export function signInScopes(card: McpConnectCardData): readonly string[] {
  return card.auth.kind === "oauth" || card.auth.kind === "device" ? card.auth.scopes : [];
}

/** Each key's value, held outside the object so no walk of it (a dump, a spread, JSON) finds it. */
const SECRETS = new WeakMap<McpConnectKey, string>();
const REDACTED = "McpConnectKey(••••••)";

/** A key the person typed into the card's private field. It never shows its value: not in
 * `String()`, `JSON.stringify`, a console dump or a test failure, so a key cannot reach a
 * transcript by being printed. The host hands `reveal()` to the daemon and drops it. */
export class McpConnectKey {
  constructor(value: string) {
    SECRETS.set(this, value.trim());
  }
  get isEmpty(): boolean {
    return this.reveal().length === 0;
  }
  /** The value, for the one send to the daemon. */
  reveal(): string {
    return SECRETS.get(this) ?? "";
  }
  /** Same key (the flow's equality, never its text). */
  equals(other: McpConnectKey): boolean {
    return this.reveal() === other.reveal();
  }
  toString(): string {
    return REDACTED;
  }
  toJSON(): string {
    return REDACTED;
  }
  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return REDACTED;
  }
}

/** Where the card is. */
export type McpPhase =
  /** The facts and Connect / Cancel. */
  | { kind: "ask" }
  /** A key server: the private field is shown. */
  | { kind: "enterKey" }
  /** The sign-in page is open; cmux waits for it to finish. */
  | { kind: "signingIn" }
  /** Approved and signed in; listing the tools. */
  | { kind: "connecting" }
  | { kind: "connected"; tools: readonly McpTool[] }
  | { kind: "declined" }
  | { kind: "failed"; reason: string };

/** What the host must send for the step just taken (mcpHost.ts names the op of each). */
export type McpEffect =
  /** `_acpmux/mcp_connect_answer {approve: true, scope}`. */
  | { kind: "approve"; scope: McpScope }
  /** `_acpmux/mcp_connect_answer {approve: false}`. */
  | { kind: "decline" }
  /** `_acpmux/mcp_key_submit`: the key goes to the daemon only, never into this state. */
  | { kind: "submitKey"; key: McpConnectKey }
  /** `_acpmux/mcp_auth_begin`, then open the URL it returns in a cmux browser tab. */
  | { kind: "beginSignIn" };

/** The card's state machine: the person's choices move it, the daemon's answers move it, and
 * nothing else does. Each step returns the next flow (the old one is never changed) and the
 * effects to send. */
export class McpConnectFlow {
  private constructor(
    readonly card: McpConnectCardData,
    readonly phase: McpPhase,
    readonly scope: McpScope,
  ) {}

  static start(card: McpConnectCardData): McpConnectFlow {
    return new McpConnectFlow(card, { kind: "ask" }, card.proposedScope);
  }

  private with(phase: McpPhase, scope: McpScope = this.scope): McpConnectFlow {
    return new McpConnectFlow(this.card, phase, scope);
  }

  /** The person picks who gets the server (only while asking). */
  choose(scope: McpScope): McpConnectFlow {
    return this.phase.kind === "ask" ? this.with(this.phase, scope) : this;
  }

  /** Connect: approve with the chosen scope, then sign in or ask for the key. */
  connect(): [McpConnectFlow, McpEffect[]] {
    if (this.phase.kind !== "ask") return [this, []];
    const approve: McpEffect = { kind: "approve", scope: this.scope };
    switch (this.card.auth.kind) {
      case "none":
        return [this.with({ kind: "connecting" }), [approve]];
      case "oauth":
      case "device":
        return [this.with({ kind: "signingIn" }), [approve, { kind: "beginSignIn" }]];
      case "key":
        return [this.with({ kind: "enterKey" }), [approve]];
    }
  }

  /** The key from the private field. An empty key connects only an optional-key server. */
  submit(key: McpConnectKey): [McpConnectFlow, McpEffect[]] {
    if (this.phase.kind !== "enterKey") return [this, []];
    if (key.isEmpty) {
      if (this.card.auth.kind !== "key" || !this.card.auth.optional) return [this, []];
      return [this.with({ kind: "connecting" }), []];
    }
    return [this.with({ kind: "connecting" }), [{ kind: "submitKey", key }]];
  }

  /** Cancel (any time before connected). */
  cancel(): [McpConnectFlow, McpEffect[]] {
    switch (this.phase.kind) {
      case "connected":
      case "declined":
      case "failed":
        return [this, []];
      default:
        return [this.with({ kind: "declined" }), [{ kind: "decline" }]];
    }
  }

  /** The daemon saw the sign-in finish. */
  signedIn(): McpConnectFlow {
    return this.phase.kind === "signingIn" ? this.with({ kind: "connecting" }) : this;
  }

  /** The daemon connected and listed the tools. */
  connected(tools: readonly McpTool[]): McpConnectFlow {
    return this.phase.kind === "connecting" || this.phase.kind === "signingIn"
      ? this.with({ kind: "connected", tools })
      : this;
  }

  /** The daemon failed (sign-in refused, server down, metadata refused). */
  failed(reason: string): McpConnectFlow {
    return this.phase.kind === "connected" || this.phase.kind === "declined"
      ? this
      : this.with({ kind: "failed", reason });
  }
}

/** The card's looks (design section 8); every look shows the same facts and controls, only the
 * arrangement differs. `factsTable` is the default. */
export type McpCardStyle = "compactRow" | "factsTable" | "permissionSheet" | "twoStep" | "bubble" | "dangerForward";
export const MCP_CARD_STYLES: readonly McpCardStyle[] = [
  "compactRow",
  "factsTable",
  "permissionSheet",
  "twoStep",
  "bubble",
  "dangerForward",
];
