import { useSyncExternalStore } from "react";

/// How a sender's icon (SenderIcon.tsx) tells one session from another of the same model family:
/// Settings > Agent Chat > Sender Icon (Swift AgentPaneDisplaySettingsSchema has the same rows; the
/// palette, the `cmux settings` CLI and the MCP settings tools write them). Leo, 2026-11-05: "you
/// either have the model family be the big one or the small one, and then you have the, like,
/// colored either robot symbol or the sort of, you know, the diamond symbol".
/// `lead`: which one is big, the family's mark (`family`, the default) or the session's badge.
/// `badge`: the session's glyph in its own stable tone (agentTones.ts): the diamond (the default,
/// "which I kind of personally like"), the robot, or none (the family's mark alone).
/// `corner`: where the small one sits on the big one.
export type SenderIconLead = "family" | "session";
export type SenderIconBadge = "diamond" | "robot" | "none";
export type SenderIconCorner = "bottom-right" | "bottom-left" | "top-right" | "top-left";
export type SenderIconLook = { lead: SenderIconLead; badge: SenderIconBadge; corner: SenderIconCorner };

export const SENDER_ICON_LEAD_KEY = "agentPane.display.senderIcon.lead";
export const SENDER_ICON_BADGE_KEY = "agentPane.display.senderIcon.badge";
export const SENDER_ICON_CORNER_KEY = "agentPane.display.senderIcon.corner";

export const SENDER_ICON_LEADS: readonly SenderIconLead[] = ["family", "session"];
export const SENDER_ICON_BADGES: readonly SenderIconBadge[] = ["diamond", "robot", "none"];
export const SENDER_ICON_CORNERS: readonly SenderIconCorner[] = [
  "bottom-right",
  "bottom-left",
  "top-right",
  "top-left",
];

export const DEFAULT_SENDER_ICON_LOOK: SenderIconLook = { lead: "family", badge: "diamond", corner: "bottom-right" };

const pick = <T extends string>(choices: readonly T[], value: unknown, fallback: T): T =>
  choices.find((choice) => choice === value) ?? fallback;

/// The look the chat's keys name; a key missing or unknown keeps its default.
export function resolveSenderIconLook(values: Readonly<Record<string, unknown>>): SenderIconLook {
  return {
    lead: pick(SENDER_ICON_LEADS, values[SENDER_ICON_LEAD_KEY], DEFAULT_SENDER_ICON_LOOK.lead),
    badge: pick(SENDER_ICON_BADGES, values[SENDER_ICON_BADGE_KEY], DEFAULT_SENDER_ICON_LOOK.badge),
    corner: pick(SENDER_ICON_CORNERS, values[SENDER_ICON_CORNER_KEY], DEFAULT_SENDER_ICON_LOOK.corner),
  };
}

let current = DEFAULT_SENDER_ICON_LOOK;
const listeners = new Set<() => void>();

/// The host's chat keys (chatDisplay.ts `setChatDisplay`): every sender icon follows at once.
export function configureSenderIconLook(values: Readonly<Record<string, unknown>>): void {
  const next = resolveSenderIconLook(values);
  if (next.lead === current.lead && next.badge === current.badge && next.corner === current.corner) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The look now, outside React.
export const senderIconLook = (): SenderIconLook => current;

/// The look now.
export const useSenderIconLook = (): SenderIconLook => useSyncExternalStore(subscribe, snapshot, snapshot);
