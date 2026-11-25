/// Auto as where a new chat runs (Leo, 2026-11-22: "the selection for auto as an environment choice
/// between cloud/local/whatever is the whole point"): the Where menu's Auto row. The page decides
/// nothing: on Send it asks this machine's daemon (`_acpmux/place_chat`, acpmux server/place.rs),
/// which reads this machine's budget and calls the one placement function
/// (`cmux_host_budget::place::decide`, cmuxterm-hq RFD 0032 "Place"), and answers a place and the
/// reason as data. The chat then starts there through the same path the explicit pick uses (a local
/// send, or the Cloud start). The arrival line says where it went, in plain words, and offers to
/// bring it back. No daemon that answers, no Cloud, or not signed in: the chat runs here and the line
/// says why; never an error.

import type { StringKey } from "./i18n";

/// The daemon request (acpmux rpc.rs `MUX_PLACE_CHAT`).
export const PLACE_CHAT_METHOD = "_acpmux/place_chat";

/// The line for a scale-up admission warning. The daemon's warning is one-shot, so the page only
/// receives this wording when `scalingUp` is true (`session/new` `_meta.acpmux.admission`).
export function autoAddingMachineLine(admission: unknown): StringKey | undefined {
  return admission &&
    typeof admission === "object" &&
    !Array.isArray(admission) &&
    (admission as { scalingUp?: unknown }).scalingUp === true
    ? "auto.addingMachine"
    : undefined;
}

/// How Auto draws in the chip and the menu (autoWhere.css). `split` ships (Leo 2026-11-24: "the auto
/// icon i assume necessarily has to be the half and half computer/cloud icon with the angled slash");
/// the rest are the gallery's variants (AutoWhere.gallery.tsx).
export type AutoLook = "split" | "orbit" | "constellation" | "aurora" | "plain";
export const AUTO_LOOK: AutoLook = "split";

/// A place Auto may put the chat, with what is known of its room (place.rs `Headroom`). Data, so the
/// list is not two places hard-coded: Cloud today, the person's own machines later.
export type AutoTarget = { place: string; headroom: "room" | "unknown" | "stale" | { full: string[] } };

/// The Cloud target: offered (signed in, or not known to be signed out, and Cloud offered for this
/// chat) it has room, since the app takes a machine sized for the chat; else none.
export function autoTargets({ cloudOffered, signedIn }: { cloudOffered: boolean; signedIn?: boolean }): AutoTarget[] {
  return cloudOffered && signedIn !== false ? [{ place: "cloud", headroom: "room" }] : [];
}

/// The daemon's answer (place.rs `Decision` plus `why`).
export type AutoDecision = {
  placement: { at: "here" } | { at: "there"; place: string };
  reason: { code: string; level?: string; over?: string[]; places?: unknown[] };
  why?: string;
};

/// Where an Auto chat landed and why: what the arrival line reads.
export type AutoLanding = {
  went: "here" | "cloud";
  /// The reason's code (place.rs `Reason`), or `no_daemon` when no daemon answered.
  code: string;
  /// The daemon's own sentence, for the line's hover.
  why?: string;
};

/// Reads a reply into a decision; anything else is none.
export function parseAutoDecision(reply: unknown): AutoDecision | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const { placement, reason, why } = reply as Record<string, unknown>;
  if (!placement || typeof placement !== "object" || !reason || typeof reason !== "object") return undefined;
  const at = (placement as { at?: unknown }).at;
  const place = (placement as { place?: unknown }).place;
  const code = (reason as { code?: unknown }).code;
  if (typeof code !== "string") return undefined;
  const parsed = { reason: reason as AutoDecision["reason"], ...(typeof why === "string" ? { why } : {}) };
  if (at === "here") return { placement: { at: "here" }, ...parsed };
  if (at === "there" && typeof place === "string") return { placement: { at: "there", place }, ...parsed };
  return undefined;
}

/// The landing a decision makes. Only a place the page can start a chat on counts (Cloud today); any
/// other runs here, as a refusal would.
export function landingOf(decision: AutoDecision | undefined): AutoLanding {
  if (!decision) return { went: "here", code: "no_daemon" };
  const why = decision.why ? { why: decision.why } : {};
  if (decision.placement.at === "there" && decision.placement.place === "cloud")
    return { went: "cloud", code: decision.reason.code, ...why };
  return { went: "here", code: decision.reason.code, ...why };
}

/// Asks the daemon where this chat runs. `request` is the connection's request (DirectClient);
/// none, or a failure, is the landing `no_daemon`: the chat runs here. Never rejects.
export async function decideAuto(
  request: ((method: string, params: Record<string, unknown>) => Promise<unknown>) | undefined,
  targets: AutoTarget[],
): Promise<AutoLanding> {
  if (!request) return landingOf(undefined);
  try {
    return landingOf(parseAutoDecision(await request(PLACE_CHAT_METHOD, { where: "auto", targets })));
  } catch {
    return landingOf(undefined);
  }
}

/// The decided send's outcome: `refused` runs if it did not go (refused now, or its promise
/// rejected), so the next Send asks the daemon again. A decision lasts one send.
export function whenSendRefused(sent: boolean | void | Promise<unknown>, refused: () => void): void {
  if (sent === false) refused();
  else if (sent instanceof Promise) sent.catch(refused);
}

/// The arrival line's sentence for a landing: one plain sentence, the same words wherever it shows.
export function landingTextKey(landing: AutoLanding): StringKey {
  if (landing.went === "cloud") return "auto.wentCloud";
  switch (landing.code) {
    case "within_budget":
      return "auto.keptHere";
    case "no_room":
      return "auto.keptHereNoCloud";
    default:
      return "auto.keptHereUnread";
  }
}

/// The arrival line's action: back to this Mac from Cloud, or on to Cloud from here when Cloud
/// could take it. Both are the chat's existing moves (Bring Back Local, Move to Cloud).
export function landingMove(landing: AutoLanding): "bringBack" | "move" {
  return landing.went === "cloud" ? "bringBack" : "move";
}

/// The destination's seed carries the UUID of the Auto start that opened it. Independent starts
/// can arrive in either order, even when their first prompts are identical.
const LANDING_PREFIX = "cmux.autoWhere.cloudLanding.";
const LANDING_TTL_MS = 30 * 60_000;

export function keepCloudLanding(landing: AutoLanding, startKey: string, now = Date.now()): void {
  try {
    globalThis.localStorage?.setItem(LANDING_PREFIX + startKey, JSON.stringify({ landing, at: now }));
  } catch {
    // The chat can still start when its page has no storage.
  }
}

export function takeCloudLanding(startKey: string | undefined, now = Date.now()): AutoLanding | undefined {
  if (!startKey) return undefined;
  try {
    const key = LANDING_PREFIX + startKey;
    const store = globalThis.localStorage;
    const raw = store?.getItem(key);
    if (!raw) return undefined;
    store.removeItem(key);
    const { landing, at } = JSON.parse(raw);
    if (
      typeof at === "number" &&
      now >= at &&
      now - at <= LANDING_TTL_MS &&
      landing?.went === "cloud" &&
      typeof landing.code === "string"
    )
      return { went: "cloud", code: landing.code, ...(typeof landing.why === "string" ? { why: landing.why } : {}) };
  } catch {
    // Storage may be unavailable or hold an unreadable entry.
  }
  return undefined;
}
