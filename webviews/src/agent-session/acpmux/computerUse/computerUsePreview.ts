// The chat's live preview card of computer use (`computerUsePreview`, CmuxNextAgentPane
// AgentPaneComputerUsePreview): while this chat's agent drives an app, the host pushes the app's
// name and its newest frame; when the session ends, `done`, and the card keeps the last frame. The
// host owns the card; the page draws it and sends a click back as `chat.computerUsePreview
// {action}` (`open`: Agent Activity on the session, `close`: hide it). A module store, so a push
// that arrives before the chat mounts is kept.
//
// The card never covers the chat: while it shows, the column's end moves in by its room
// (`COMPUTER_USE_PREVIEW_RESERVE`, `--cv-inset-end`), as the Codex app narrows its chat beside the
// preview. A pane too narrow to give that room shows no card. With Session Info open, the card sits
// under Session Info's card (session-info/underSessionInfo.ts). Floating, the column keeps its room, so
// opening or closing Session Info never reflows the chat; Settings Push always's column keeps the
// chat clear of both instead.
//
// The person drags the card anywhere in the pane, enlarges it or fills the pane with it, hides it and
// brings it back from a small chip (Leo, 2026-11-22: "WHERE IS THE FUCKING PREVIEW OF THE FUCKING
// RUNNING SITUATION AND THE ABILITY TO DRAG IT AROUND AND FUCKING HIDE IT"). Where it sits and whether
// it shows is the daemon's (cmux-tui remote_host/computer_use_preview_place.rs): each push carries
// `place {x, y, size}` and `hidden`, and the page sends a move back as `chat.computerUsePreview
// {action: "place", x?, y?, size?}` (`close` hides, `show` brings it back). Until the host's push agrees,
// the page shows the person's move at once (`moveComputerUsePreview`); a host that sends no place
// keeps the page's.
//
// The agent's cursor and the person's pointer reach the card as telepointers: fractions of the
// previewed window with a visible flag and an age, metadata beside the frame and never drawn into
// it. That model is ported from Petal's telepointers (kiruna-labs/petal @ 7ac436a,
// web-harness/src/telepointer.ts and telepointerDisplay.ts, Apache-2.0).
import { useSyncExternalStore } from "react";

/// The card's room at the chat's right: its 180px, 12px from the pane's edge, a 12px gap to the
/// column (computerUsePreview.css).
export const COMPUTER_USE_PREVIEW_RESERVE = 204;
/// The narrowest pane that shows the card: narrower, the column it leaves is too narrow to read.
export const COMPUTER_USE_PREVIEW_MIN_PANE = 600;

export type ComputerUsePreview = {
  /// The Computer Use session the card shows.
  session: string;
  /// The app's name ("Calculator"), or its window's title; "" when the host knows neither. The
  /// card shows no name: it is in the card's label only, which then names no app.
  app: string;
  /// The session ended: the last frame, dimmed, with the app's icon and a check.
  done: boolean;
  /// The newest frame, a `data:image/...` URL.
  frame: string;
  /// The app's icon, a `data:image/png` URL, sent with the done state when the host found one.
  icon?: string;
  /// The agent's cursor in the frame (0...1 from the top left), the newest click's id and the
  /// window's width in points: the card draws the helper's own cursor there, at the window's scale,
  /// and plays a click when the id changes. Running cards only.
  pointer?: ComputerUsePreviewPointer;
  /// The agent's cursor and the person's pointer over the window, each when the host knows it.
  /// Running cards only.
  telepointers?: ComputerUsePreviewTelepointers;
  /// Where the card sits in the pane and how large it is (the daemon's, or the person's move the
  /// daemon has not echoed yet); absent from a host that keeps no place.
  place?: ComputerUsePreviewPlace;
  /// The person hid it: the pane shows the "Show Preview" chip instead.
  hidden?: boolean;
};

export type ComputerUsePreviewSize = "small" | "large" | "full";
/// Two fractions of the room the pane leaves around the card (0 the left or top edge, 1 the right or
/// bottom), so the card stays inside the pane at any size; and its size.
export type ComputerUsePreviewPlace = { x: number; y: number; size: ComputerUsePreviewSize };
/// Where a new session's card sits: the top right, small (where it always sat).
export const DEFAULT_COMPUTER_USE_PREVIEW_PLACE: ComputerUsePreviewPlace = { x: 1, y: 0, size: "small" };
/// What the person changed: the page's own until the host's push says the same.
export type ComputerUsePreviewMove = Partial<ComputerUsePreviewPlace> & { hidden?: boolean };

export type ComputerUsePreviewPointer = { x: number; y: number; click: number; windowWidth?: number };

/// A pointer over the previewed window: a fraction of it (0...1 from the top left), whether it is
/// inside the window (outside, the point is clamped to the edge and the card hides it), and how long
/// ago it last moved when the host knows. `idle`: it has stayed still long enough to dim.
export type ComputerUsePreviewTelepointer = { x: number; y: number; visible: boolean; ageMs?: number; idle: boolean };
export type ComputerUsePreviewTelepointers = {
  agent?: ComputerUsePreviewTelepointer;
  person?: ComputerUsePreviewTelepointer;
};

/// How long the person's pointer stays still before the card dims it (the host's
/// ComputerUseLiveCapture.personIdle).
export const PERSON_POINTER_IDLE_MS = 2000;

const isFraction = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;

/// The pointer of a host push, or undefined (none, or a malformed one).
function readPointer(value: unknown): ComputerUsePreviewPointer | undefined {
  const raw = value as Partial<ComputerUsePreviewPointer> | null | undefined;
  if (!raw || typeof raw !== "object" || !isFraction(raw.x) || !isFraction(raw.y)) return undefined;
  if (typeof raw.click !== "number" || !Number.isFinite(raw.click)) return undefined;
  const width = raw.windowWidth;
  const windowWidth = typeof width === "number" && Number.isFinite(width) && width > 0 ? width : undefined;
  return { x: raw.x, y: raw.y, click: raw.click, ...(windowWidth ? { windowWidth } : {}) };
}

const samePointer = (a?: ComputerUsePreviewPointer, b?: ComputerUsePreviewPointer) =>
  a?.x === b?.x && a?.y === b?.y && a?.click === b?.click && a?.windowWidth === b?.windowWidth;

/// One telepointer of a host push, or undefined (none, or a malformed one).
function readTelepointer(value: unknown): ComputerUsePreviewTelepointer | undefined {
  const raw = value as Partial<ComputerUsePreviewTelepointer> | null | undefined;
  if (!raw || typeof raw !== "object" || !isFraction(raw.x) || !isFraction(raw.y)) return undefined;
  if (typeof raw.visible !== "boolean") return undefined;
  const age = raw.ageMs;
  const ageMs = typeof age === "number" && Number.isFinite(age) && age >= 0 ? age : undefined;
  const idle = raw.idle === true || (ageMs !== undefined && ageMs >= PERSON_POINTER_IDLE_MS);
  return { x: raw.x, y: raw.y, visible: raw.visible, ...(ageMs === undefined ? {} : { ageMs }), idle };
}

/// The telepointers of a host push, or undefined when it has none that read.
function readTelepointers(value: unknown): ComputerUsePreviewTelepointers | undefined {
  const raw = value as { agent?: unknown; person?: unknown } | null | undefined;
  if (!raw || typeof raw !== "object") return undefined;
  const agent = readTelepointer(raw.agent);
  const person = readTelepointer(raw.person);
  if (!agent && !person) return undefined;
  return { ...(agent ? { agent } : {}), ...(person ? { person } : {}) };
}

const SIZES: readonly ComputerUsePreviewSize[] = ["small", "large", "full"];
const isSize = (value: unknown): value is ComputerUsePreviewSize => SIZES.includes(value as ComputerUsePreviewSize);
const clampFraction = (value: number) => Math.min(1, Math.max(0, value));

/// The place of a host push, or undefined (none, or a malformed one).
function readPlace(value: unknown): ComputerUsePreviewPlace | undefined {
  const raw = value as Partial<ComputerUsePreviewPlace> | null | undefined;
  if (!raw || typeof raw !== "object") return undefined;
  const { x, y, size } = raw;
  if (typeof x !== "number" || !Number.isFinite(x) || typeof y !== "number" || !Number.isFinite(y)) return undefined;
  return { x: clampFraction(x), y: clampFraction(y), size: isSize(size) ? size : "small" };
}

const samePlace = (a?: ComputerUsePreviewPlace, b?: ComputerUsePreviewPlace) =>
  a?.x === b?.x && a?.y === b?.y && a?.size === b?.size;

/// The age is not compared: a push that only re-ages a pointer changes nothing on screen.
const sameTelepointer = (a?: ComputerUsePreviewTelepointer, b?: ComputerUsePreviewTelepointer) =>
  a?.x === b?.x && a?.y === b?.y && a?.visible === b?.visible && a?.idle === b?.idle;
const sameTelepointers = (a?: ComputerUsePreviewTelepointers, b?: ComputerUsePreviewTelepointers) =>
  sameTelepointer(a?.agent, b?.agent) && sameTelepointer(a?.person, b?.person);

let current: ComputerUsePreview | null = null;
/// The session the person closed here: hidden at once, before the host's push that takes it away.
let closed: string | undefined;
/// The person's moves the host has not echoed yet, by session (a few per page).
const moves = new Map<string, ComputerUsePreviewMove>();
/// What the page draws: the host's card with the person's moves over it.
let shown: ComputerUsePreview | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  shown = withMoves(current);
  for (const listener of listeners) listener();
}

function withMoves(card: ComputerUsePreview | null): ComputerUsePreview | null {
  return card && withMove(card, moves.get(card.session), card.session === closed);
}

/// `card` with the person's `move` over it; `closedHere`: the person closed it on this page.
function withMove(
  card: ComputerUsePreview,
  move: ComputerUsePreviewMove | undefined,
  closedHere: boolean,
): ComputerUsePreview | null {
  // Closed here and the host does not keep a hidden card (an older host): gone, as before.
  if (closedHere && card.hidden !== true && move?.hidden !== true) return null;
  if (!move) return card;
  const { hidden, ...place } = move;
  const merged: ComputerUsePreview = {
    ...card,
    place: { ...(card.place ?? DEFAULT_COMPUTER_USE_PREVIEW_PLACE), ...place },
  };
  if (hidden !== undefined) merged.hidden = hidden;
  return merged;
}

/// Whether the host's card already says what the person's move asked for.
function echoes(card: ComputerUsePreview, move: ComputerUsePreviewMove): boolean {
  if (!card.place) return false;
  const { hidden, ...place } = move;
  if (hidden !== undefined && (card.hidden === true) !== hidden) return false;
  return samePlace(card.place, { ...card.place, ...place });
}

/// Only an image `data:` URL draws: the page's CSP allows `img-src data:`, and nothing else is
/// taken from the push.
const isImage = (value: unknown): value is string => typeof value === "string" && value.startsWith("data:image/");

/// The card of a host push, or null (no card, or a malformed one).
export function readComputerUsePreview(value: unknown): ComputerUsePreview | null {
  const raw = value as Partial<ComputerUsePreview> | null | undefined;
  if (!raw || typeof raw !== "object" || typeof raw.session !== "string" || !raw.session) return null;
  if (!isImage(raw.frame)) return null;
  const done = raw.done === true;
  const pointer = done ? undefined : readPointer(raw.pointer);
  const telepointers = done ? undefined : readTelepointers(raw.telepointers);
  const place = readPlace(raw.place);
  return {
    session: raw.session,
    app: typeof raw.app === "string" ? raw.app : "",
    done,
    frame: raw.frame,
    ...(isImage(raw.icon) ? { icon: raw.icon } : {}),
    ...(pointer ? { pointer } : {}),
    ...(telepointers ? { telepointers } : {}),
    ...(place ? { place } : {}),
    ...(raw.hidden === true ? { hidden: true } : {}),
  };
}

/// Replaces the card from a host push.
export function setComputerUsePreview(value: unknown): void {
  const next = readComputerUsePreview(value);
  if (
    next?.session === current?.session &&
    next?.frame === current?.frame &&
    next?.done === current?.done &&
    next?.app === current?.app &&
    next?.icon === current?.icon &&
    samePointer(next?.pointer, current?.pointer) &&
    sameTelepointers(next?.telepointers, current?.telepointers) &&
    samePlace(next?.place, current?.place) &&
    next?.hidden === current?.hidden
  )
    return;
  // The host had this card hidden, as asked here, and now shows it with nothing pending here: another
  // surface brought it back, so the close made on this page is over.
  if (
    next &&
    closed === next.session &&
    current?.session === next.session &&
    current.hidden === true &&
    next.hidden !== true &&
    !moves.has(next.session)
  )
    closed = undefined;
  current = next;
  // The host speaks for the place once its push says what the person asked for.
  const move = next ? moves.get(next.session) : undefined;
  if (next && move && echoes(next, move)) moves.delete(next.session);
  notify();
}

export function currentComputerUsePreview(): ComputerUsePreview | null {
  return shown;
}

/// Hides the card of `session` here at once (the close button); the host's next push agrees.
export function closeComputerUsePreview(session: string): void {
  if (closed === session && moves.get(session)?.hidden === true) return;
  closed = session;
  moveComputerUsePreview(session, { hidden: true });
}

/// Brings back the card of `session` the person hid (the chip).
export function showComputerUsePreview(session: string): void {
  if (closed === session) closed = undefined;
  moveComputerUsePreview(session, { hidden: false });
}

/// The person moved, resized, hid or showed the card of `session`: drawn at once, until the host's push
/// agrees.
export function moveComputerUsePreview(session: string, move: ComputerUsePreviewMove): void {
  if (moves.size >= 16 && !moves.has(session)) moves.clear();
  moves.set(session, { ...moves.get(session), ...move });
  notify();
}

/// The place the card draws at.
export const computerUsePreviewPlace = (preview: ComputerUsePreview): ComputerUsePreviewPlace =>
  preview.place ?? DEFAULT_COMPUTER_USE_PREVIEW_PLACE;

/// Whether the card sits where the column keeps its room (the top right, small, shown): moved, larger or
/// hidden, the column takes its room back.
export function computerUsePreviewDocked(preview: ComputerUsePreview): boolean {
  if (preview.hidden) return false;
  return samePlace(computerUsePreviewPlace(preview), DEFAULT_COMPUTER_USE_PREVIEW_PLACE);
}

/// How far a press may move before it is a drag, not a click (CSS pixels).
export const COMPUTER_USE_PREVIEW_DRAG_SLOP = 4;

/// A drag of `delta` pixels from `from` (a fraction), in a room `room` pixels long (the pane's side less
/// the card's and its margins): the new fraction, kept inside the room.
export function dragFraction(from: number, delta: number, room: number): number {
  if (!(room > 0)) return clampFraction(from);
  return clampFraction(from + delta / room);
}

/// The app's name the card's label says: trimmed, or none.
export const computerUsePreviewTitle = (preview: ComputerUsePreview): string | undefined =>
  preview.app.trim() || undefined;

const roomQuery = `(min-width: ${COMPUTER_USE_PREVIEW_MIN_PANE}px)`;
const subscribeRoom = (listener: () => void) => {
  if (typeof window === "undefined" || !window.matchMedia) return () => undefined;
  const query = window.matchMedia(roomQuery);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
};
const hasRoom = () => typeof window === "undefined" || !window.matchMedia || window.matchMedia(roomQuery).matches;

/// Whether the pane is wide enough to show the card beside the column (the page is the pane).
export function useComputerUsePreviewRoom(): boolean {
  return useSyncExternalStore(subscribeRoom, hasRoom, hasRoom);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useComputerUsePreview(): ComputerUsePreview | null {
  return useSyncExternalStore(subscribe, currentComputerUsePreview, currentComputerUsePreview);
}

/// `card` with the person's moves over it, redrawn on each move: the card draws a move at once
/// whoever gave it the card (the app's store already has them; this adds nothing then).
export function useComputerUsePreviewMoves(card: ComputerUsePreview | null): ComputerUsePreview | null {
  // The session's own move and closed flag are the snapshots (a move stores a new object), so a
  // memoized render (React Compiler) keys on them: a store read whose result went unused let
  // the compiler keep the card drawn before the move.
  const session = card?.session;
  const moveOf = () => (session === undefined ? undefined : moves.get(session));
  const closedOf = () => session !== undefined && session === closed;
  const move = useSyncExternalStore(subscribe, moveOf, moveOf);
  const closedHere = useSyncExternalStore(subscribe, closedOf, closedOf);
  return card && withMove(card, move, closedHere);
}

declare global {
  interface Window {
    /// The old host's script for the `computerUsePreview` event (CmuxNextAgentPane AgentPaneComputerUsePreview).
    cmuxAcpmuxComputerUsePreview?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxComputerUsePreview = setComputerUsePreview;
