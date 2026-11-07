// The Chat Colors page's ops with its host (HomeChatColorsService.swift, design/home.md "Chat Colors").
// The page owns no data: the host opens a session per chat, streams the chat's stored colours and
// the colours the chat draws with after every change (a pick here, `cmux chat colors`, a theme or
// `home.bubbleColors.*` change), and stores each pick through HomeChatColorStore.set, the same code
// the CLI runs. Every call carries the session id, so a late one never changes a newer chat.

export const ChatColorsOps = {
  /** Stream: one event per open (`{id, conversation, name}`), the current one first. */
  session: "cmux.home.chatColors.session",
  /** Stream: the chat's colours and the resolved preview, again after every change. */
  state: "cmux.home.chatColors.state",
  /** `{session, role, color}`: one role's colour (`#RRGGBB`), or null for Default / Automatic. */
  set: "cmux.home.chatColors.set",
  /** `{session}`: clears every role (Reset to Default). */
  reset: "cmux.home.chatColors.reset",
  /** `{session}`: closes the panel (Done, Return, Escape). */
  done: "cmux.home.chatColors.done",
  /** `{session, role}`: opens the system colour panel for the role; its picks stream back as state. */
  customColor: "cmux.home.chatColors.customColor",
} as const;

/** The four colours of a chat, as HomeBubbleColors names them. */
export type ChatColorRole = "sent" | "sentText" | "received" | "receivedText";

export const CHAT_COLOR_ROLES: readonly ChatColorRole[] = ["sent", "sentText", "received", "receivedText"];

export interface ChatColorsSession {
  /** Echoed by every call, so a late one never applies to a newer chat. */
  readonly id: string;
  readonly conversation: string;
  /** The chat's name (the panel's title shows it). */
  readonly name: string;
}

/** A bubble's resolved colours, `#RRGGBB`. */
export interface ChatColorsPair {
  readonly fill: string;
  readonly text: string;
}

/** The colours the chat draws with: its page colour and both sides' bubbles. */
export interface ChatColorsPreview {
  readonly background: string;
  readonly sent: ChatColorsPair;
  readonly received: ChatColorsPair;
}

export interface ChatColorsState {
  /** The session the state belongs to; another session's state is dropped. */
  readonly session: string;
  /** The chat's own colours (`#RRGGBB`); a role it has none for is null or missing. */
  readonly colors: Partial<Record<ChatColorRole, string | null>>;
  readonly preview: ChatColorsPreview;
}

/** Messages' blue first, then the colours Messages and the system use most. */
export const SENT_SWATCHES = ["#0A84FF", "#34C759", "#AF52DE", "#FF2D55", "#FF9500", "#FFD60A", "#30B0C7", "#8E8E93"];
export const RECEIVED_SWATCHES = ["#E9E9EB", "#3B3B3D", "#D6EAFF", "#D9F7E0", "#EADCF8", "#FFE5CC", "#1C2A4A"];
/** The text rows' fixed choices after Automatic: white, then black. */
export const TEXT_SWATCHES = ["#FFFFFF", "#000000"];

/** A colour as the store writes it (`HomeColor.hex`): `#RRGGBB`, or `#RRGGBBAA` when not opaque
 * (`cmux chat colors` takes either). `#RGB` widens to `#RRGGBB`; an `FF` alpha is dropped, as the
 * store drops it; any other alpha is kept, so a translucent colour matches no opaque swatch. Null
 * for anything else. */
export function normalizeHex(value: unknown): string | null {
  if (typeof value !== "string") return null;
  let text = value.trim().replace(/^#/, "").toUpperCase();
  if (text.length === 3) text = text.replace(/./g, "$&$&");
  if (!/^[0-9A-F]{6}([0-9A-F]{2})?$/.test(text)) return null;
  if (text.endsWith("FF") && text.length === 8) text = text.slice(0, 6);
  return `#${text}`;
}

/** Whether the chat has colours of its own (Reset to Default is enabled). */
export function hasOwnColors(state: ChatColorsState | null): boolean {
  return !!state && CHAT_COLOR_ROLES.some((role) => normalizeHex(state.colors[role]) !== null);
}
