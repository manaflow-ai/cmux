// What the line above the composer says when the pane cannot reach its chat, and when it says it.
//
// Leo, 2026-10-30, on a red card that read "peer_unreachable: <host> (reconnecting, last seen 10s
// ago: WebSocket protocol error: Handshake not finished); the request was not sent; run `acpmux host
// ls` and retry after the peer reconnects": "it was literally just loading. Then it gave me that red
// message, like I could have fucking done something. But no, it was just a slow fucking connection.
// So, like, that's not the fucking right time to be showing that kind of fucking message."
//
// So: a chat whose machine is connecting, reconnecting or slow shows nothing (the prompt stays in
// the composer and goes once the machine answers); a line shows only once the person can act on
// it, and then in plain words. acpmux's own words (a `snake_case:` code, link state, a CLI command
// to run) are for its CLI and logs: the composer never shows them, only its Details disclosure does.
import type { Translate } from "./i18n";

/// acpmux's reasons for a request that failed because the chat's machine is not reachable now
/// (`peer_link.rs` `unreachable_error`, `peer.rs` `fail_link_requests`). The daemon keeps
/// reconnecting such a machine on its own.
const PEER_LINK_REASONS = new Set(["peer_unreachable", "peer_disconnected"]);

/// A peer link state in which the machine is on its way up or merely slow, never gone
/// (`peer_link.rs` `PeerState`): `connecting` is acpmux's first attempt, still in flight;
/// `degraded` is an open socket whose handshake has not finished or a ping that went unanswered;
/// `restarting` is a daemon that announced its restart and reconnects at once. The pane never says
/// anything while a machine is in one of these. (A first attempt that failed is `offline`, and a
/// link lost after it was up is `reconnecting`: those are said past the deadline.)
const SLOW_PEER_STATES = new Set(["connecting", "degraded", "restarting"]);

/// How long a chat's machine may stay unreachable (reconnecting, or never reached yet) before the
/// pane says so. acpmux never stops reconnecting a peer; two minutes without a link means the machine
/// is really gone (asleep, off the network), not a slow connection, so the person may want to act.
export const PEER_LINK_DEADLINE_MS = 120_000;

export type PeerLinkFailure = {
  /// The machine's name, when acpmux says it (a forwarded refusal names none, `redact.rs`).
  peer?: string;
  /// The machine's link state when the request failed (`peer_link.rs` `PeerState::as_str`).
  peerState?: string;
};

function fieldsOf(error: unknown): Record<string, unknown> | undefined {
  return error && typeof error === "object" ? (error as Record<string, unknown>) : undefined;
}

/// The request failed because the chat's machine is not reachable now (acpmux `peer_unreachable` or
/// `peer_disconnected`), read from the error's reason (direct.ts copies `data.reason` there), its
/// data, or acpmux's message code; undefined for every other failure.
export function peerLinkFailure(error: unknown): PeerLinkFailure | undefined {
  const fields = fieldsOf(error);
  const data = fieldsOf(fields?.data);
  const reason = typeof fields?.reason === "string" ? fields.reason : data?.reason;
  const message = typeof fields?.message === "string" ? fields.message : typeof error === "string" ? error : "";
  const coded = /^peer[_ ](?:unreachable|disconnected)\b/.test(message);
  if (!(typeof reason === "string" && PEER_LINK_REASONS.has(reason)) && !coded) return undefined;
  // A bridge that kept only the message still says the machine and its link state there
  // (`peer_link.rs` `describe`: `peer_unreachable: NAME (STATE, last seen …)`).
  const described = /^peer_unreachable: ([^\s(;]+) \(([a-z]+)\b/.exec(message);
  const peer = typeof data?.peer === "string" && data.peer ? data.peer : described?.[1];
  const peerState = typeof data?.peerState === "string" && data.peerState ? data.peerState : described?.[2];
  return { ...(peer ? { peer } : {}), ...(peerState ? { peerState } : {}) };
}

/// Whether a failure of the chat's machine link is said after it has lasted `failingForMs`: never
/// while the machine is slow or restarting, else once it has been unreachable past
/// ``PEER_LINK_DEADLINE_MS``.
export function peerLinkFailureShows(failure: PeerLinkFailure, failingForMs: number): boolean {
  if (failure.peerState && SLOW_PEER_STATES.has(failure.peerState)) return false;
  return failingForMs >= PEER_LINK_DEADLINE_MS;
}

/// acpmux's own words, which the composer never shows: a `snake_case:` or `dotted.code:` prefix
/// (`peer_unreachable: …`, `spawn.failed: …`), a command in backticks, or an instruction to run one.
const RAW_CODE = /(^|[\s(])[a-z][a-z0-9]*(?:[._][a-z0-9]+)+:/;
const CLI_TEXT = /`[^`]+`|\b(?:run|try) (?:`|acpmux\b|cmux\b)|\bacpmux (?:host|peer|doctor|ls|status|web)\b/i;
const PROTOCOL_TEXT = /\b(?:WebSocket protocol|JSON-RPC|errno|ECONN[A-Z]+|EPIPE|ETIMEDOUT)\b/;

/// Whether `text` carries acpmux's or the transport's own words: a code, a CLI command or protocol
/// detail. Such text goes behind the line's Details, never on it.
export function isRawDaemonText(text: string): boolean {
  return RAW_CODE.test(text) || CLI_TEXT.test(text) || PROTOCOL_TEXT.test(text);
}

/// The plain line for a chat whose machine is not reachable, naming the machine when it is known.
export function peerLinkLine(failure: PeerLinkFailure, t: Translate, machineName?: string): string {
  const machine = failure.peer ?? machineName;
  return machine ? t("host.peerUnreachable", { machine }) : t("host.peerUnreachableUnnamed");
}

export type HostLineText = {
  /// The one plain line.
  line: string;
  /// The failure in acpmux's own words, shown only behind the line's Details; absent when the line
  /// already says all of it.
  detail?: string;
};

/// The line for a failure the pane says, in plain words. The chat's machine is named when acpmux or
/// the handshake names it (`machineName`); acpmux's raw text moves behind Details.
export function hostLineText(error: unknown, message: string, t: Translate, machineName?: string): HostLineText {
  const peer = peerLinkFailure(error) ?? peerLinkFailure(message);
  const raw = message.trim();
  if (peer) {
    const line = peerLinkLine(peer, t, machineName);
    return raw && raw !== line ? { line, detail: raw } : { line };
  }
  if (!raw) return { line: t("host.unavailable") };
  if (isRawDaemonText(raw)) return { line: t("host.unavailable"), detail: raw };
  return { line: raw };
}
