// Where a prompt was sent from: acpmux's `sender_claim` record (acpmux sender_harness.rs), written
// beside a prompt sent with `acpmux send` (or acpmux's MCP send) from a harness or an app: Claude
// Code in Claude desktop, a terminal or the SDK, Codex, an MCP client such as an assistant agent.
// `claimed` is what the sender's own environment said (self-reported, so anything could have
// said it); `checked` is what the daemon found walking the process chain from the socket's peer
// pid, and the program it found running the send (`program`, acpmux sender_program.rs). Neither
// names who sent it: the row's sender stays what acpmux's provenance says.
//
// Leo, 2026-11-07: "could it possibly detect that you sent it as the Claude Code desktop?"
// A claim the daemon's look does not confirm is never drawn as if proven: when the daemon found the
// program, the chip names that program and the claim is only said in its tooltip (Leo, 2026-11-11,
// on our outbox relay's python drawn as an "Xcode" chip: "generally the "unverified sender" things
// should be more verified").

export type SentFrom = {
  promptId: string;
  /** The harness or app, as it reported itself (`claude-code`, `codex`, an MCP client's name). */
  harness: string;
  /** What the person reads: "Claude desktop", "Claude Code", "Codex", or the reported name; the
   * program the daemon found (`outbox_relay.py`) when the claim is not confirmed. */
  label: string;
  /** The claim's own label, when the chip names the found program instead. */
  claimedLabel?: string;
  /** The harness's own session id (Claude Code's `CLAUDE_CODE_SESSION_ID`, Codex's thread). */
  sessionId?: string;
  /** Claude desktop's own session id (`local_…`). */
  hostSessionId?: string;
  /** What the daemon found in the sender's process chain, when it could look. */
  checked?: { harness?: string; app?: string; signedBy?: string; program?: string };
  /** The daemon's look agrees with the claim. False with no look, or when it found another. */
  confirmed: boolean;
};

const MAX = 128;

function field(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text && text.length <= MAX && !/\p{Cc}/u.test(text) ? text : undefined;
}

function label(harness: string, entrypoint: string | undefined, app: string | undefined): string {
  if (harness === "claude-code") {
    if (entrypoint === "claude-desktop" || app === "Claude.app") return "Claude desktop"; // l10n-allow: product name
    if (entrypoint?.startsWith("sdk")) return "Claude Agent SDK"; // l10n-allow: product name
    return "Claude Code"; // l10n-allow: product name
  }
  if (harness === "codex") return "Codex"; // l10n-allow: product name
  return harness;
}

/// A `sender_claim` record's message, read for the row of the prompt it names; undefined for one
/// with no prompt id or no harness.
export function sentFrom(msg: unknown): SentFrom | undefined {
  if (typeof msg !== "object" || msg === null) return undefined;
  const record = msg as { promptId?: unknown; claimed?: Record<string, unknown>; checked?: Record<string, unknown> };
  const promptId = field(record.promptId);
  const claimed = typeof record.claimed === "object" && record.claimed !== null ? record.claimed : undefined;
  const harness = field(claimed?.harness);
  if (!promptId || !harness) return undefined;
  const raw = typeof record.checked === "object" && record.checked !== null ? record.checked : undefined;
  const checked = raw && {
    ...(field(raw.harness) && { harness: field(raw.harness) }),
    ...(field(raw.app) && { app: field(raw.app) }),
    ...(field(raw.signedBy) && { signedBy: field(raw.signedBy) }),
    ...(field(raw.program) && { program: field(raw.program) }),
  };
  const entrypoint = field(claimed?.entrypoint);
  const app = field(claimed?.app);
  // A Claude desktop claim, by its entrypoint or by the app it names, holds only under Claude.app,
  // which confirms it alone (the chain can find the app with no harness binary on it); any claim
  // naming an app holds only when the daemon found that app.
  const desktop = harness === "claude-code" && (entrypoint === "claude-desktop" || app === "Claude.app");
  const confirmed =
    !!checked &&
    (checked.harness === harness || (!!app && checked.app === app) || (desktop && checked.app === "Claude.app")) &&
    (!app || checked.app === app) &&
    (!desktop || checked.app === "Claude.app");
  const claimedLabel = label(harness, entrypoint, app ?? (confirmed ? checked?.app : undefined));
  const found = !confirmed ? checked?.program : undefined;
  return {
    promptId,
    harness,
    label: found ?? claimedLabel,
    ...(found && { claimedLabel }),
    ...(field(claimed?.sessionId) && { sessionId: field(claimed?.sessionId) }),
    ...(field(claimed?.hostSessionId) && { hostSessionId: field(claimed?.hostSessionId) }),
    ...(checked && Object.keys(checked).length > 0 && { checked }),
    confirmed,
  };
}
