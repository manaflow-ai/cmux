// Chat widget cards (plans/cmux-next/chat-widgets-DESIGN.md section 4): the host's snapshot of a
// widget part as the page reads it, and the card's layout. Ported from the deleted native rows,
// MessagesLabHome `HomeWidgetLayout.swift` (sizes, item cap, text line cap, which items take a click)
// and CmuxHomeRender `HomeWidgetSnapshot.swift` (the items); the host's side is CmuxNextHome
// `HomeMessagesWidgets.swift`.
//
//   widget.snapshot {key, widget: {app, widget, props, fallback, url?}} -> {items} | null
//   widget.tap {key, node}: a click on a row or button (a click only)
//   widget.keep {keys}: the keys the page shows; their mounts live while it does
//   widget (stream) {key, snapshot}: a widget's new snapshot as its app changes it
import type { HomeWidgetPart } from "../../../home-channels/types";

export const WidgetOps = {
  snapshot: "cmux.home.messages.widget.snapshot",
  tap: "cmux.home.messages.widget.tap",
  keep: "cmux.home.messages.widget.keep",
  changes: "cmux.home.messages.widget",
} as const;

/** A semantic colour the card resolves with the page's palette (light and dark). */
export type WidgetTint = "primary" | "secondary" | "accent" | "success" | "warning" | "danger";
export type WidgetTextStyle = "headline" | "body" | "caption";

export interface WidgetButton {
  /** The scene node a click goes to. */
  node: string;
  title: string;
  /** Filled with the accent: the widget's main action. */
  prominent: boolean;
  /** A disabled button draws dimmed and takes no click. */
  enabled: boolean;
}

export type WidgetItem =
  | { type: "text"; text: string; style: WidgetTextStyle; tint: WidgetTint }
  | { type: "row"; node?: string; title: string; subtitle?: string; symbol?: string; tint: WidgetTint; badge?: string }
  | { type: "buttons"; buttons: WidgetButton[] }
  | { type: "badge"; text: string; tint: WidgetTint }
  | { type: "divider" }
  | { type: "empty"; title: string; message?: string; symbol?: string };

/** What one widget shows now: its items, top to bottom. */
export interface WidgetSnapshot {
  items: WidgetItem[];
}

/** The card's measures (widget.css), HomeWidgetLayout's on the page's spacing scale: 8 padding and
 * 8 between items for its 10 and 6, 32 rows for 34 (CSS px for its points). */
export const WIDGET_LAYOUT = {
  maxWidth: 340,
  minWidth: 120,
  padX: 12,
  padY: 8,
  spacing: 8,
  rowHeight: 32,
  buttonHeight: 28,
  buttonGap: 8,
  badgeHeight: 20,
  maxTextLines: 4,
  /** The most items a card draws (HomeWidgetSnapshot.maxItems): longer lists are the app's to page. */
  maxItems: 14,
  lineHeight: { headline: 16, body: 16, caption: 14 } as Record<WidgetTextStyle, number>,
  /** Characters a body line holds at the card's width (the estimate's only text measure). */
  charsPerLine: 44,
} as const;

/** `<message id>#<part index>`: the widget's mount and storage key (HomeWidgetRowProvider.key). */
export const widgetKey = (message: string, partIndex: number): string => `${message}#${partIndex}`;

type Json = Record<string, unknown>;
const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const str = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const TINTS = new Set<WidgetTint>(["primary", "secondary", "accent", "success", "warning", "danger"]);
const STYLES = new Set<WidgetTextStyle>(["headline", "body", "caption"]);
const tintOf = (value: unknown, fallback: WidgetTint): WidgetTint =>
  TINTS.has(value as WidgetTint) ? (value as WidgetTint) : fallback;

function item(value: unknown): WidgetItem | undefined {
  const raw = record(value);
  switch (raw?.type) {
    case "text": {
      const text = str(raw.text);
      if (!text) return undefined;
      const style = STYLES.has(raw.style as WidgetTextStyle) ? (raw.style as WidgetTextStyle) : "body";
      return { type: "text", text, style, tint: tintOf(raw.tint, "primary") };
    }
    case "row": {
      const row: Extract<WidgetItem, { type: "row" }> = {
        type: "row",
        title: typeof raw.title === "string" ? raw.title : "",
        tint: tintOf(raw.tint, "secondary"),
      };
      if (str(raw.node)) row.node = String(raw.node);
      if (str(raw.subtitle)) row.subtitle = String(raw.subtitle);
      if (str(raw.symbol)) row.symbol = String(raw.symbol);
      if (str(raw.badge)) row.badge = String(raw.badge);
      return row;
    }
    case "buttons": {
      const buttons: WidgetButton[] = [];
      for (const entry of Array.isArray(raw.buttons) ? raw.buttons : []) {
        const button = record(entry);
        const node = str(button?.node);
        const title = str(button?.title);
        if (!button || !node || !title) continue;
        buttons.push({ node, title, prominent: button.prominent === true, enabled: button.enabled !== false });
      }
      return buttons.length ? { type: "buttons", buttons } : undefined;
    }
    case "badge": {
      const text = str(raw.text);
      return text ? { type: "badge", text, tint: tintOf(raw.tint, "secondary") } : undefined;
    }
    case "divider":
      return { type: "divider" };
    case "empty": {
      const empty: Extract<WidgetItem, { type: "empty" }> = {
        type: "empty",
        title: typeof raw.title === "string" ? raw.title : "",
      };
      if (str(raw.message)) empty.message = String(raw.message);
      if (str(raw.symbol)) empty.symbol = String(raw.symbol);
      return empty;
    }
    default:
      return undefined;
  }
}

/** The host's snapshot, or undefined (null, loading, no app, or not one): the card draws its fallback.
 * Items the page does not know are skipped; at most ``WIDGET_LAYOUT.maxItems``. */
export function parseWidgetSnapshot(value: unknown): WidgetSnapshot | undefined {
  const raw = record(value);
  if (!raw || !Array.isArray(raw.items)) return undefined;
  const items: WidgetItem[] = [];
  for (const entry of raw.items) {
    const parsed = item(entry);
    if (parsed) items.push(parsed);
    if (items.length === WIDGET_LAYOUT.maxItems) break;
  }
  return { items };
}

/** A `widget` stream event, or undefined. */
export function parseWidgetChange(event: unknown): { key: string; snapshot: WidgetSnapshot | undefined } | undefined {
  const raw = record(event);
  const key = str(raw?.key);
  return raw && key ? { key, snapshot: parseWidgetSnapshot(raw.snapshot) } : undefined;
}

/** The part as `widget.snapshot` sends it. */
export const widgetWire = (part: HomeWidgetPart) => ({
  app: part.app,
  widget: part.widget,
  props: part.props,
  fallback: part.fallback,
  ...(part.url ? { url: part.url } : {}),
});

/** The scene nodes a card's clicks may reach: clickable rows and enabled buttons (HomeWidgetLayout
 * `node(at:)`); a badge, text, a divider, a disabled button or a row with no node take none. */
export function clickableNodes(snapshot: WidgetSnapshot): string[] {
  const out: string[] = [];
  for (const entry of snapshot.items) {
    if (entry.type === "row" && entry.node) out.push(entry.node);
    if (entry.type === "buttons") for (const button of entry.buttons) if (button.enabled) out.push(button.node);
  }
  return out;
}

/** The lines a text item takes at the card's width, at most ``WIDGET_LAYOUT.maxTextLines``. */
export function textLines(text: string): number {
  const lines = text
    .split("\n")
    .reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / WIDGET_LAYOUT.charsPerLine)), 0);
  return Math.min(Math.max(1, lines), WIDGET_LAYOUT.maxTextLines);
}

/** One item's height (HomeWidgetLayout's per-item heights). */
export function itemHeight(entry: WidgetItem): number {
  const L = WIDGET_LAYOUT;
  switch (entry.type) {
    case "text":
      return textLines(entry.text) * L.lineHeight[entry.style];
    case "row":
      return L.rowHeight;
    case "buttons":
      return entry.buttons.length ? L.buttonHeight : 0;
    case "badge":
      return L.badgeHeight;
    case "divider":
      return 1;
    case "empty":
      // About the symbol, the title and the message, as HomeWidgetLayout's 52 and 68.
      return entry.message ? 68 : 52;
  }
}

/** The card's height: the padding, each item and the spacing between them (HomeWidgetLayout.size). */
export function widgetHeight(snapshot: WidgetSnapshot): number {
  const L = WIDGET_LAYOUT;
  const items = snapshot.items.slice(0, L.maxItems);
  if (!items.length) return 2 * L.padY;
  const body = items.reduce((sum, entry) => sum + itemHeight(entry), 0) + L.spacing * (items.length - 1);
  return Math.ceil(2 * L.padY + body);
}

/** The fallback bubble's height: a text bubble at the card's width (Fixture's 7 px padding, 16 px lines). */
export function fallbackHeight(fallback: string): number {
  const lines = fallback
    .split("\n")
    .reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / WIDGET_LAYOUT.charsPerLine)), 0);
  return 14 + 16 * Math.min(lines, 400);
}
