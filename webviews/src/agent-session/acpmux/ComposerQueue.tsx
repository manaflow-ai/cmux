// Prompts waiting for the running turn, as compact rows over the composer: one muted line each, cut
// with an ellipsis, with no header and no number (Leo, 2026-10-21, as ChatGPT and Codex draw them);
// the list's own name ("Queued prompts") says what they are. The list takes its own
// place at the top of the composer form, over its location strip, so the transcript, a question
// waiting for an answer and the pull requests above the composer each keep theirs: none is cut
// off or drawn over, and the transcript scrolls in what is left.
//
// Keyboard first: ↑ on an empty prompt goes to the last row; on a row, ↑/↓ move between rows (↓
// past the last goes back to the prompt), Return edits it in place, ⌥↑/⌥↓ move it in the queue
// and Delete removes it. Esc goes back to the prompt.
//
// Every row shows ChatGPT's and Codex's actions, in their order, on hover and while focus is in the
// row (Leo, 2026-10-21: "is this really
// the right order? ... I thought we had a trash can"): Steer (its word beside its ↪ glyph), a trash
// can that deletes the prompt, and a ⋯ menu with Edit message, Open in side chat (where the chat
// can open one) and Turn off queueing (queueing.ts). Steer is the user's override: it steers the
// prompt into the running turn and stops only its current step, so the agent reads it at once and
// the turn runs on; to an agent that cannot steer it runs next. It never cancels a turn. Only a
// click steers, never a key: a held or repeated key once sent row after row (claude-sr2,
// 2026-10-20). The row's right-click menu has Steer, Edit message, the moves and Delete.
//
// Another agent's message waiting in the queue (`message`, direct.ts `queuedMessage`) is not the
// person's prompt, and it is no row here (Leo, 2026-10-25: "I don't know why these things are queued
// up"): the transcript draws it at once as its received card, with its actions in the card's ⋯ menu
// (conversation/queuedMessages.ts). The rows, the fold and its count are the person's prompts alone.
//
// A prompt's images show as small thumbnails under its text (QueuedImages.tsx), each opening the
// image viewer; while it is edited each has a remove control, and Save keeps only the images left
// (Leo, 2026-10-21).
//
// After a failed turn acpmux pauses the queue: a note above the rows says so, with Resume.
//
// A long queue folds (Leo, 2026-10-14): past three of the person's queued prompts it shows the next two and one
// "N more queued" row, which opens the whole list in place and closes it back ("Show less"). The
// fold is a button (aria-expanded) under the list, outside its scrolling, so ↑ from the prompt
// reaches it first and no row runs under it. Opened, the list keeps about its folded height
// (composerStates.css), so the chat above moves one row at most, and scrolls freely: a scroll rests
// where it stops, its end too. It stays open for its chat until closed (not across reloads);
// prompts sent now always show.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Icon } from "./icons/Icon";
import { QueuedImages } from "./QueuedImages";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import type { ComposerAttachment } from "./attachments";
import type { Translate } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../ui/Menu";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";
import { lacksImageBytes, ownQueue, queuedAttachments } from "./conversation/queuedMessages";
import { setQueueing, useQueueing } from "./queueing";
import { AuthorChip } from "./multiplayer/Faces";
import {
  pickedSkillsOf,
  withSkillDollars,
  withoutSkillDollars,
  type SkillCatalog,
  type SlashCommand,
} from "./slashCommands";
import { useSkillWords } from "./conversation/skillWords";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/** A queue of more queued prompts than this folds; folded, it shows `FOLD_SHOWS` of them. */
const FOLD_AT = 3;
const FOLD_SHOWS = 2;
/** The chats whose long queue is open, for this page's life. */
const openQueues = new Set<string>();

// The list rests on whole rows (captures of 436917b and f1a737b, 2026-10-15). Its height is the
// bottom of the last row that fits under its cap: the CSS cap folded, the third row's bottom opened
// (so opening moves the chat above by about a row, whatever the rows' heights), and opening lands at
// its top. A row focused from the keyboard scrolls in whole (the paused note with the first);
// a press never scrolls the list (the row under it moved before the release, so a click on a row the
// edge cut landed on another or none: Leo, 2026-10-20). A row the edge cuts still draws (a blank
// slot read as a missing prompt).

/** Where `el` sits in the list's content, from its top (not moved by scrolling). */
function offsets(list: HTMLElement, el: Element) {
  const origin = list.getBoundingClientRect().top - list.scrollTop;
  const rect = el.getBoundingClientRect();
  return { top: rect.top - origin, bottom: rect.bottom - origin };
}

/** Sizes the list to whole rows under its cap. */
function fitList(list: HTMLElement) {
  // The list's own window (a test's DOM has no global one).
  const style = list.ownerDocument.defaultView?.getComputedStyle(list);
  if (!style) return;
  const pad = parseFloat(style.paddingBottom) || 0;
  const items = [...list.children].filter((el) => !el.hasAttribute("hidden"));
  const rows = items.filter((el) => el.classList.contains("acpmux-queued"));
  const opened = list.hasAttribute("data-unfolded") && rows.length > 3;
  // Where the list would end after each part: at its bottom, or after the last one, below the
  // list's padding (the padding under a row the list cuts off would show the next row's top).
  const ends = items.map((el, index) => offsets(list, el).bottom + (index === items.length - 1 ? pad : 0));
  let cap = opened ? offsets(list, rows[2]).bottom : parseFloat(style.getPropertyValue("--acpmux-queue-max")) || 132;
  // The paused note and the next prompt always show whole, even one opened past the cap.
  if (rows[0]) cap = Math.max(cap, ends[items.indexOf(rows[0])]);
  const fit = ends.filter((end) => end <= cap + 0.5).at(-1) ?? cap;
  const height = `${fit}px`;
  if (list.style.maxHeight !== height) list.style.maxHeight = height;
}

/// The queue's fit-ready marker is a paint boundary, but a gallery/test DOM may expose a window
/// without requestAnimationFrame. Keep the marker and its cleanup deterministic there too.
function requestFitFrame(document: Document, callback: FrameRequestCallback): number {
  const view = document.defaultView;
  if (typeof view?.requestAnimationFrame === "function") return view.requestAnimationFrame(callback);
  if (typeof globalThis.requestAnimationFrame === "function") return globalThis.requestAnimationFrame(callback);
  return setTimeout(() => callback(Date.now()), 0) as unknown as number;
}

function cancelFitFrame(document: Document, handle: number): void {
  const view = document.defaultView;
  if (typeof view?.cancelAnimationFrame === "function") view.cancelAnimationFrame(handle);
  else if (typeof globalThis.cancelAnimationFrame === "function") globalThis.cancelAnimationFrame(handle);
  else clearTimeout(handle);
}

/** Scrolls the list so `row` shows whole, starting at a row's top (the paused note's, for the first). */
function reveal(list: HTMLElement, row: HTMLElement) {
  const { top, bottom } = offsets(list, row);
  const view = list.clientHeight;
  let to = list.scrollTop;
  if (top < to - 0.5) {
    const before = row.previousElementSibling;
    const anchor = before && !before.classList.contains("acpmux-queued") ? before : row;
    to = anchor === list.firstElementChild ? 0 : offsets(list, anchor).top;
  } else if (bottom > to + view + 0.5) {
    const starts = [...list.children].map((el) => offsets(list, el).top);
    to = starts.find((start) => start >= bottom - view - 0.5) ?? bottom - view;
  }
  if (Math.abs(to - list.scrollTop) > 0.5) list.scrollTop = to;
}

/// The text a row shows, whole: the prompt, or for acpmux's resume of a subagent its label, name and
/// error. Never the resume's raw prompt, which names the agent id and tells the agent how to resume it.
export function shownText(entry: QueuedEntry, t: Translate, skills?: SkillCatalog): string {
  const retry = entry.retry;
  if (!retry) return withoutSkillDollars(entry.prompt, skills);
  return [`${t("composer.queuedSubagentRetry")} ${retry.name ?? retry.agentId ?? ""}`.trim(), retry.error]
    .filter(Boolean)
    .join("\n");
}

/// The most a held list may grow to: the room the pane leaves the composer's stack, that is the
/// floating dock's max-height and the pane under its header (44px) less the transcript's least room
/// (64px, bottomStack.css), whichever is less. Not the list's resting cap (--acpmux-queue-max): a
/// row opened under the pointer may take the list past it, so nothing under the pointer moves.
function heldCap(list: HTMLElement, now: number): number {
  const view = list.ownerDocument.defaultView;
  let cap = Infinity;
  const dock = list.closest<HTMLElement>(".acpmux-dock");
  const dockMax = dock ? parseFloat(view?.getComputedStyle(dock).maxHeight ?? "") : NaN;
  if (dock && Number.isFinite(dockMax)) cap = Math.min(cap, now + dockMax - dock.getBoundingClientRect().height);
  const main = list.closest<HTMLElement>(".acpmux-main");
  if (main) cap = Math.min(cap, now + list.getBoundingClientRect().top - (main.getBoundingClientRect().top + 44 + 64));
  return cap;
}

/** Row `id` of `list`, matched by its prompt id (no selector escaping: an id may hold any character). */
function rowOf(list: HTMLElement | null | undefined, id: string): HTMLElement | undefined {
  return [...(list?.querySelectorAll<HTMLElement>(":scope > .acpmux-queued") ?? [])].find(
    (row) => row.dataset.promptId === id,
  );
}

/** Shows the row's whole text as a tooltip only when its one line (the button's inner text) cuts it off. */
function titleWhenTruncated(event: React.PointerEvent<HTMLElement>, prompt: string) {
  const button = event.currentTarget;
  const text = button.firstElementChild ?? button;
  if (text.scrollWidth > text.clientWidth || text.scrollHeight > text.clientHeight + 1) button.title = prompt;
  else button.removeAttribute("title");
}

/// Bridge failures whose request may already have reached acpmux (it answered late, the socket
/// closed after sending, or the reply was malformed or lost after the edit applied: `native.failed`);
/// every other rejection (`native.not_connected`, a typed refusal) means the edit was not applied.
const UNCERTAIN_CODES = new Set([
  "native.timed_out",
  "native.failed",
  "transport.closed",
  "transport.stale_connection",
]);
const mayHaveReachedAcpmux = (error: unknown) => {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && UNCERTAIN_CODES.has(code);
};

export function ComposerQueue({
  queue,
  chat,
  paused,
  pauseReason,
  t,
  onRemove,
  onCancelEdit,
  onChange,
  onLost,
  onLeave,
  readImage,
  onSideChat,
  commands,
}: {
  queue: AcpmuxSnapshot["queue"];
  /// The chat the queue belongs to: a long queue opened stays open for it.
  chat?: string;
  /// A turn failed and the queue waits for Resume (acpmux `queuePaused`).
  paused?: boolean;
  /// That turn's error (queuePause.ts), which the paused note names.
  pauseReason?: string;
  t: Translate;
  /// Withdraws a waiting prompt; false when it already started (it then leaves with the turn).
  onRemove?(id: string): Promise<boolean>;
  /// Pulls a queued prompt into the composer, preserving its text and images.
  onCancelEdit?(id: string, text: string, attachments: ComposerAttachment[]): Promise<boolean>;
  /// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
  onChange?(id: string, edit: QueueEdit): Promise<boolean>;
  /// An edit of a prompt that started meanwhile: its text goes back to the prompt, so it is kept.
  /// `id` is the prompt's row.
  onLost?(text: string, id: string): void;
  /// Focus leaves the queue for the prompt.
  onLeave?(): void;
  /// Reads an image a queued prompt sends by its acpmux id, as a data URL (`_acpmux/attachment`).
  readImage?(id: string): Promise<string | undefined>;
  /// Opens a side chat that asks this prompt (as `/btw` does) and withdraws it from the queue; false
  /// when it already started. Absent where the chat opens no side chat.
  onSideChat?(id: string, prompt: string): Promise<boolean>;
  /// The chat's command list: a queued prompt reads its Codex skills `/name` and an edit saves them
  /// as `/$name` (slashCommands.ts), a skill added in the edit too.
  commands?: readonly SlashCommand[];
}) {
  const skills = useSkillWords(commands);
  // A row leaves as soon as it is removed; it comes back only if acpmux kept it waiting.
  const [leaving, setLeaving] = useState<ReadonlySet<string>>(new Set());
  const leavingNow = useRef(leaving);
  leavingNow.current = leaving;
  // A successful Send now is reflected by acpmux's next snapshot, but the action must disappear
  // immediately after the queue_edit reply so a second click cannot resend it.
  const [sentNow, setSentNow] = useState<ReadonlySet<string>>(new Set());
  const queueing = useQueueing();
  const [editing, setEditingId] = useState<string>();
  // The open edit as the latest render saw it, for a call that settles later.
  const editingNow = useRef<string | undefined>(undefined);
  editingNow.current = editing;
  // Each row's latest Save: an older one that settles after a newer one began must not reopen its
  // superseded text (the newer save's editor, or its result, is the one that counts).
  const saveGeneration = useRef(new Map<string, number>());
  // Saves not yet answered, per row. Cancel and edit waits for them: it hands the composer the text
  // the row shows, which a Save in flight is about to change, and a Save failing after the row was
  // taken back would restore its own text beside it.
  const savesPending = useRef(new Map<string, number>());
  const settleSave = (id: string) => {
    const left = (savesPending.current.get(id) ?? 1) - 1;
    if (left > 0) savesPending.current.set(id, left);
    else savesPending.current.delete(id);
  };
  // The authoritative queue and the rows hidden while their removal is pending, for calls that settle later.
  const queueNow = useRef(queue);
  queueNow.current = queue;
  // Typed text of Saves that failed before acpmux had them while another editor was open (or a
  // sibling's recovery was just claimed): each waits, per row, for the editor to be free again.
  const recovered = useRef(new Map<string, { text: string; original: string; generation: number }>());
  // The images the open edit drops from its prompt.
  const [dropped, setDropped] = useState<ReadonlySet<string>>(new Set());
  const setEditing = (id: string | undefined) => {
    setDropped(new Set());
    setEditingId(id);
  };
  // Rows opened to their whole text (a row shows two lines until it is opened).
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  // Opening or closing a row under the pointer never moves what is under the pointer (Leo,
  // 2026-10-30: "its expansion animation makes the hovered buttons shift layout"). A row's actions
  // sit on its last line (composerStates.css), and the list sits on the composer, so it grows and
  // shrinks at its top: the list changes by exactly what the row did, at once and with no
  // animation, so the row's last line, its actions and every row below stay where they were, and
  // all of the opened text shows (no scroll). Until the pointer leaves, the list keeps that height
  // instead of fitting its rows again; then it fits them.
  const held = useRef(false);
  // The pointer that pressed a row's text, read by its click.
  const pressedBy = useRef<string>(undefined);
  // A row the pointer just opened or closed, with its height and the list's before, for the
  // layout effect that sizes the list once the row draws.
  const resized = useRef<{ id: string; row: number; list: number }>(undefined);
  // The row whose pointer toggle holds the list: the hold is that row's, and goes with it.
  const heldId = useRef<string>(undefined);
  // While a hold lasts: the observers that give room back when the stack around the list grows.
  const holding = useRef<{ disconnect(): void }>(undefined);
  /** Ends the hold now: the list fits its rows again. */
  const release = (current: HTMLElement | null) => {
    held.current = false;
    heldId.current = undefined;
    holding.current?.disconnect();
    holding.current = undefined;
    if (!current) return;
    // Fit while [data-held] still turns the max-height transition off, and have the browser take
    // the new height (a style read) before the transition comes back: the list shrinks at once,
    // never animating down over a blank band (closing takes effect on the click).
    current.style.removeProperty("min-height");
    fitList(current);
    void current.ownerDocument.defaultView?.getComputedStyle(current).maxHeight;
    current.removeAttribute("data-held");
  };
  const toggle = (id: string, hovered: boolean) => {
    // Only a hovering pointer's click holds it: a key or a touch has no pointer on the list to
    // leave it, and must never keep the list from fitting.
    held.current = hovered;
    heldId.current = hovered ? id : undefined;
    const current = list.current;
    const row = rowOf(current, id);
    resized.current =
      hovered && current && row
        ? { id, row: row.getBoundingClientRect().height, list: current.getBoundingClientRect().height }
        : undefined;
    if (!hovered) {
      current?.style.removeProperty("min-height");
      current?.removeAttribute("data-held");
    }
    setOpen((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  };
  // The list follows the row the pointer opened or closed, by exactly its change, before the frame
  // paints.
  useLayoutEffect(() => {
    const was = resized.current;
    const current = list.current;
    if (!was || !current) return;
    resized.current = undefined;
    const row = rowOf(current, was.id);
    if (!row) return;
    const want = Math.max(0, was.list + row.getBoundingClientRect().height - was.row);
    // Never past the list's own cap, nor past the room the pane leaves the stack: a very long prompt
    // in a short pane would otherwise push the composer off the pane. Past it, the list scrolls.
    const height = Math.min(want, Math.max(was.list, heldCap(current, was.list)));
    // No max-height transition for this change (composerStates.css [data-held]).
    current.setAttribute("data-held", "");
    current.style.maxHeight = `${height}px`;
    current.style.minHeight = `${height}px`;
    // Capped, the opened row's end (its error, its last lines) scrolls into view inside the list.
    if (height < want - 0.5) {
      const end = offsets(current, row).bottom - current.clientHeight;
      if (end > current.scrollTop) current.scrollTop = end;
    }
  }, [open]);
  // A hold outlives nothing it holds for: once its row leaves the queue (deleted, sent, steered,
  // run), or a row leaving makes the held height more than the rows left need, the list fits its
  // rows at once instead of keeping a blank band until the pointer leaves.
  useLayoutEffect(() => {
    const current = list.current;
    if (!held.current || !current) return;
    const rows = [...current.querySelectorAll<HTMLElement>(":scope > .acpmux-queued")];
    if (!heldId.current || !rows.some((row) => row.dataset.promptId === heldId.current)) return release(current);
    const last = current.lastElementChild;
    const pad = parseFloat(current.ownerDocument.defaultView?.getComputedStyle(current).paddingBottom ?? "") || 0;
    const need = last ? offsets(current, last).bottom + pad : 0;
    if (need < parseFloat(current.style.minHeight || "0") - 0.5) release(current);
  });
  // A held list gives room back when the stack around it grows (a permission card or a question
  // arrives under the pointer, the pane shortens): past the room the pane leaves the stack, or by
  // what a part above it has had to give up since the hold began (bottomStack.css shrinks those
  // first, so a card would otherwise sit cut to one row over a held queue), it shrinks and scrolls.
  // While a hold lasts, a ResizeObserver on the dock, the pane, the parts above the list and their
  // contents, and a MutationObserver for parts that arrive; both disconnect when the hold ends or
  // the list goes.
  useLayoutEffect(() => {
    const current = list.current;
    if (!held.current || !current) {
      holding.current?.disconnect();
      holding.current = undefined;
      return;
    }
    if (holding.current || typeof ResizeObserver === "undefined") return;
    const view = current.ownerDocument.defaultView;
    const dock = current.closest<HTMLElement>(".acpmux-dock");
    const main = current.closest<HTMLElement>(".acpmux-main");
    /// The parts of the stack drawn above the list (a question, a permission card, notices).
    const above = () =>
      dock
        ? [...dock.querySelectorAll<HTMLElement>(":scope > *, :scope > .acpmux-composer > *")].filter(
            (part) =>
              part !== current &&
              !part.contains(current) &&
              (part.compareDocumentPosition(current) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0,
          )
        : [];
    /// How much of its own height (to its own max-height) the stack has squeezed out of a part.
    const squeezed = (part: HTMLElement) => {
      const max = parseFloat(view?.getComputedStyle(part).maxHeight ?? "");
      return Math.max(0, Math.min(part.scrollHeight, Number.isFinite(max) ? max : Infinity) - part.clientHeight);
    };
    // What each part had given up when the hold began: only what it gives up after is handed back,
    // so the hold itself never moves the list under the pointer.
    const before = new WeakMap(above().map((part) => [part, squeezed(part)]));
    const shrinkToRoom = () => {
      if (!held.current || !current.isConnected) return;
      const box = current.getBoundingClientRect();
      let room = heldCap(current, box.height);
      for (const part of above()) room = Math.min(room, box.height - (squeezed(part) - (before.get(part) ?? 0)));
      if (room >= box.height - 0.5) return;
      const min = parseFloat(view?.getComputedStyle(current).getPropertyValue("--acpmux-stack-row-min") ?? "") || 34;
      const height = `${Math.max(min, room)}px`;
      current.style.maxHeight = height;
      current.style.minHeight = height;
    };
    const observer = new (view?.ResizeObserver ?? ResizeObserver)(shrinkToRoom);
    const watch = () => {
      for (const part of above()) for (const box of [part, ...part.children]) observer.observe(box);
      for (const box of [dock, main]) if (box) observer.observe(box);
    };
    watch();
    // A part that arrives later (the card), or a card a part gains, is watched too and measured at once.
    const arrivals = new (view?.MutationObserver ?? MutationObserver)(() => {
      watch();
      shrinkToRoom();
    });
    if (dock) arrivals.observe(dock, { childList: true, subtree: true });
    holding.current = {
      disconnect() {
        observer.disconnect();
        arrivals.disconnect();
      },
    };
  });
  useEffect(
    () => () => {
      holding.current?.disconnect();
      holding.current = undefined;
    },
    [],
  );
  /** Fits the list to its rows, unless a row the pointer opened holds its height. */
  const fit = (current: HTMLElement) => {
    if (!held.current) fitList(current);
  };
  // What the open edit holds now: a prompt that starts while it is edited hands it to the prompt.
  const draft = useRef<{ id: string; original: string; text: string }>(undefined);
  // Reopens the next waiting recovery once the editor is free; a row that is gone by then hands its
  // text back to the composer, and one saved again since is dropped (its newer save counts).
  const reopenRecovered = () => {
    for (const [id, waiting] of recovered.current) {
      // The authoritative queue decides whether a row is gone, never what is drawn: a row hidden
      // while its removal is still pending is not gone (the removal can be refused and the row
      // come back), so its text waits for the answer instead of going to the composer too.
      const row = queueNow.current.find((entry) => entry.id === id && entry.author === undefined);
      if (row && leavingNow.current.has(id)) continue;
      recovered.current.delete(id);
      if (!row) onLost?.(waiting.text, id);
      else if (saveGeneration.current.get(id) === waiting.generation) {
        editingNow.current = id;
        draft.current = { id, original: waiting.original, text: waiting.text };
        setEditing(id);
        return;
      }
    }
  };
  // The layout effect below runs on queue changes only, and calls the latest closure.
  const reopenRecoveredRef = useRef(reopenRecovered);
  reopenRecoveredRef.current = reopenRecovered;
  // A waiting recovery is revisited when the authoritative queue, the rows hidden for a pending
  // removal, or the open editor change: a refused removal brings the row (and its text) back, an
  // accepted one hands the text to the composer.
  useLayoutEffect(() => {
    if (editing === undefined && recovered.current.size > 0) reopenRecoveredRef.current();
  }, [queue, leaving, editing]);
  // The row a move keeps focus on, once the new order draws.
  const refocus = useRef<string>(undefined);
  const list = useRef<HTMLOListElement>(null);
  // Whether a long queue shows whole (the composer keys this component by chat).
  const [unfolded, setUnfolded] = useState(() => chat !== undefined && openQueues.has(chat));
  const unfold = (next: boolean) => {
    setUnfolded(next);
    if (chat === undefined) return;
    if (next) openQueues.add(chat);
    else openQueues.delete(chat);
  };
  // The row that takes focus once it draws: the next one after a row leaves, when it was folded.
  const focusNext = useRef<string>(undefined);
  const foldButton = useRef<HTMLButtonElement>(null);
  // A press in the list, until its release: the focus it gives a row does not scroll the list.
  const pressing = useRef(false);
  useEffect(() => {
    setSentNow((current) => {
      const next = new Set(
        [...current].filter((id) => {
          const entry = queue.find((candidate) => candidate.id === id);
          return entry !== undefined && !entry.next;
        }),
      );
      return next.size === current.size ? current : next;
    });
    setLeaving((current) => {
      const kept = [...current].filter((id) => queue.some((entry) => entry.id === id));
      return kept.length === current.size ? current : new Set(kept);
    });
    // The edited prompt left, or turned out to be a teammate's (its authored record came in while
    // the editor was open): the editor closes, and what was typed goes back to the composer.
    if (editing && !queue.some((entry) => entry.id === editing && entry.author === undefined)) {
      const open = draft.current;
      if (open?.id === editing && open.text.trim() && open.text !== open.original) onLost?.(open.text.trim(), editing);
      draft.current = undefined;
      setDropped(new Set());
      setEditingId(undefined);
      editingNow.current = undefined;
      reopenRecoveredRef.current();
    }
  }, [queue, editing, onLost]);
  // Whole rows only: the list's height, after every draw, when its width changes, and when a row's
  // height does (a prompt opened to its whole text, its images read).
  const watched = useRef<{ list: HTMLElement; observer: ResizeObserver; rows: ResizeObserver }>(undefined);
  const fitReadyFrame = useRef<number | undefined>(undefined);
  const wasOpen = useRef(unfolded);
  useLayoutEffect(() => {
    const current = list.current;
    // A hold belongs to the list the pointer was on: once that list leaves (the queue emptied) no
    // pointerleave comes, so a list drawn later starts unheld.
    if (watched.current?.list !== current) {
      held.current = false;
      heldId.current = undefined;
    }
    if (current) {
      // Clear the collapsed list's scroll offset before measuring the opened rows. A pointer click
      // can leave focus on a row that the browser keeps anchored while the list grows; measuring
      // first then resetting lets that stale offset survive the max-height transition and puts a
      // row above the list's own top edge (the short-pane queue stack regression).
      const opening = unfolded && !wasOpen.current;
      if (opening) current.scrollTop = 0;
      const firstFit = !current.hasAttribute("data-fit-ready");
      fit(current);
      if (firstFit) {
        fitReadyFrame.current = requestFitFrame(current.ownerDocument, () => {
          fitReadyFrame.current = undefined;
          if (current.isConnected) current.setAttribute("data-fit-ready", "");
        });
      }
    }
    wasOpen.current = unfolded;
    if (watched.current?.list !== current) {
      watched.current?.observer.disconnect();
      watched.current?.rows.disconnect();
      watched.current = undefined;
      if (current && typeof ResizeObserver !== "undefined") {
        let width = current.clientWidth;
        const observer = new ResizeObserver(() => {
          if (current.clientWidth === width) return;
          width = current.clientWidth;
          fit(current);
        });
        observer.observe(current);
        const rows = new ResizeObserver(() => fit(current));
        watched.current = { list: current, observer, rows };
      }
    }
    // The rows drawn now; a row gone stops being watched with its element.
    const rows = watched.current?.rows;
    if (rows && current) {
      rows.disconnect();
      for (const row of current.querySelectorAll(":scope > .acpmux-queued")) rows.observe(row);
    }
  });
  useEffect(
    () => () => {
      const document = list.current?.ownerDocument;
      if (fitReadyFrame.current !== undefined && document) cancelFitFrame(document, fitReadyFrame.current);
      fitReadyFrame.current = undefined;
      watched.current?.observer.disconnect();
      watched.current?.rows.disconnect();
    },
    [],
  );
  useLayoutEffect(() => {
    const id = refocus.current;
    const row = id ? list.current?.querySelector<HTMLElement>(`[data-prompt-id="${id}"]`) : null;
    if (row && document.activeElement !== row) row.focus();
    // Only while focus is still in the queue (or was dropped with the row that left).
    const next = focusNext.current;
    const into = next ? list.current?.querySelector<HTMLElement>(`[data-prompt-id="${next}"]`) : null;
    const active = document.activeElement;
    if (into && (!active || active === document.body || list.current?.contains(active))) {
      focusNext.current = undefined;
      into.focus();
    }
  });
  const act = (id: string, action: () => Promise<boolean>) => {
    setLeaving((current) => new Set(current).add(id));
    const restore = () =>
      setLeaving((current) => {
        const next = new Set(current);
        next.delete(id);
        return next;
      });
    action().then((done) => {
      if (!done) restore();
    }, restore);
  };
  // The person's prompts only: another agent's message draws in the transcript.
  const shown = ownQueue(queue).filter((entry) => !leaving.has(entry.id));
  // A paused queue of agent messages alone still says so, with Resume.
  // Who each row belongs to, as last drawn. A native menu keeps the actions it opened with: one
  // picked after a row turned out to be a teammate's (its authored record came in while the menu
  // was open) does nothing, as the row now offers nothing.
  const owners = (rows: readonly QueuedEntry[]) =>
    rows.map((entry) => `${entry.id}\u0000${entry.author?.id ?? ""}`).join("\u0001");
  const drawnOwners = useRef("");
  const drawnRows = useRef<readonly QueuedEntry[]>([]);
  useLayoutEffect(() => {
    drawnOwners.current = owners(shown);
    drawnRows.current = shown;
  });
  if (shown.length === 0 && !(paused && queue.length > 0)) return null;
  // Prompts sent now come first: queued prompts count from after them.
  const steering = shown.filter((entry) => entry.next).length;
  // A long queue folds to its next prompts; the rows shown are always the first ones, in order.
  const foldable = shown.length - steering > FOLD_AT;
  const folded = foldable && !unfolded;
  const visible = folded ? shown.slice(0, steering + FOLD_SHOWS) : shown;

  // The rows, then the fold, in the order ↑ and ↓ walk them.
  const rows = () => [
    ...(list.current?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? []),
    ...(foldButton.current ? [foldButton.current] : []),
  ];
  const focusRow = (index: number) => {
    const all = rows();
    if (index >= all.length) onLeave?.();
    else all[Math.max(0, index)]?.focus();
  };
  // Focus after the row at `index` leaves: the prompt after it, which a folded queue shows only
  // once that row has gone, or the prompt when it was the last.
  const focusAfter = (index: number) => {
    const next = shown[index + 1];
    if (!next) return onLeave?.();
    const row = list.current?.querySelector<HTMLElement>(`[data-prompt-id="${next.id}"]`);
    if (row) return row.focus();
    focusNext.current = next.id;
    setTimeout(() => {
      if (focusNext.current === next.id) focusNext.current = undefined;
    }, 1000);
  };
  const remove = onRemove && ((entry: QueuedEntry) => act(entry.id, () => onRemove(entry.id)));
  // A teammate's prompt in a shared chat: shown with its author, never changed from here.
  const theirs = (entry: QueuedEntry) => entry.author !== undefined;
  const whileOwnersHold = (items: ContextMenuItem[]): ContextMenuItem[] => {
    const opened = owners(shown);
    return items.map((entry) => ({
      ...entry,
      onSelect: () => {
        if (drawnOwners.current === opened) entry.onSelect();
      },
    }));
  };
  const cancelEdit =
    onCancelEdit &&
    (async (entry: QueuedEntry) => {
      // A Save of this row is still out: its answer decides the text (a failed one brings it back
      // into the row's editor), so the row is taken back once it is answered.
      if (savesPending.current.has(entry.id)) return;
      const began = saveGeneration.current.get(entry.id);
      const attachments = await queuedAttachments(entry.images, readImage);
      // An image that could not be read would be lost with the row: it stays queued.
      if (lacksImageBytes(attachments)) return;
      // Its images read, the row may have turned out to be a teammate's (or gone): then it is
      // theirs, and nothing is taken out of the queue.
      const now = drawnRows.current.find((row) => row.id === entry.id);
      // A Save begun while the images were read (answered or not) changed what the row shows or
      // what its editor holds: the click is not carried out on the text it was made on.
      if (!now || theirs(now) || saveGeneration.current.get(entry.id) !== began) return;
      await act(entry.id, () => onCancelEdit(entry.id, entry.prompt, attachments));
    });
  // A side chat asks the prompt's text alone, so a prompt with images stays in the queue.
  const sideChat =
    onSideChat &&
    ((entry: QueuedEntry) =>
      entry.images?.length ? undefined : () => act(entry.id, () => onSideChat(entry.id, entry.prompt)));
  // A prompt sent now stays in place: to an agent that cannot steer acpmux marks it next
  // (`queue_order`), so its row reads Steering until it runs; to an agent that steers it leaves
  // once acpmux takes it (`dequeued`). Hiding it as leaving showed nothing until it ran (live run
  // 2026-10-14).
  const sendNow =
    onChange &&
    ((entry: QueuedEntry) => {
      if (entry.next || sentNow.has(entry.id)) return;
      void onChange(entry.id, { op: "send_now" })
        .then((ok) => {
          if (!ok) return;
          setSentNow((current) => new Set(current).add(entry.id));
        })
        .catch(() => undefined);
    });
  const canSendNow = (entry: QueuedEntry) => Boolean(sendNow && !entry.next && !sentNow.has(entry.id));
  // A move to the place of the row shown at `index` (acpmux counts rows still leaving too); the
  // moved row keeps focus once acpmux's new order draws. Past the first or last row shown, an
  // agent's waiting message (drawn in the transcript) may still be its neighbour in the queue: it
  // moves one place in the whole queue then.
  const queueIndex = (entry: QueuedEntry) => queue.findIndex((q) => q.id === entry.id);
  // Where a move to the row shown at `index` lands in the whole queue, or undefined when it cannot:
  // past either end, or across a teammate's prompt (each row it passes shifts one place, and a
  // teammate's prompt is theirs to move).
  const moveTarget = (entry: QueuedEntry, index: number): number | undefined => {
    const target = shown[index];
    const from = queueIndex(entry);
    const to = target ? queueIndex(target) : from + (index < shown.indexOf(entry) ? -1 : 1);
    if (from < 0 || to < 0 || to >= queue.length || to === from) return undefined;
    const passed = to < from ? queue.slice(to, from) : queue.slice(from + 1, to + 1);
    return passed.some((q) => q.author !== undefined) ? undefined : to;
  };
  const move =
    onChange &&
    ((entry: QueuedEntry, index: number) => {
      const to = moveTarget(entry, index);
      if (to === undefined) return;
      // A move into the folded part opens the queue, so the moved row stays in sight.
      if (folded && index >= visible.length) unfold(true);
      refocus.current = entry.id;
      void onChange(entry.id, { op: "move", index: to })
        .finally(() =>
          setTimeout(() => {
            if (refocus.current === entry.id) refocus.current = undefined;
          }, 500),
        )
        .catch(() => undefined);
    });
  // The open edit ends unsaved, its images all kept; focus goes back to its row.
  const cancel = (index: number) => {
    draft.current = undefined;
    setEditing(undefined);
    editingNow.current = undefined;
    reopenRecovered();
    focusRow(index);
  };
  const save = (entry: QueuedEntry, text: string) => {
    if (entry.author !== undefined) return cancel(shown.indexOf(entry));
    const images = entry.images ?? [];
    const kept = images.filter((image) => !dropped.has(image.id));
    draft.current = undefined;
    setEditing(undefined);
    editingNow.current = undefined;
    // A save of this row supersedes any text of its own that waited; the others get the editor next.
    recovered.current.delete(entry.id);
    reopenRecovered();
    focusRow(shown.indexOf(entry));
    // The editor shows a Codex skill `/name` (withoutSkillDollars): each goes back as `/$name`, a
    // skill the prompt named keeping that name where a command shares it.
    const next = withSkillDollars(text.trim(), skills, pickedSkillsOf(entry.prompt, skills));
    // Text alone keeps every image; an image removed sends the ones left.
    const removed = kept.length < images.length;
    if (!next || (next === entry.prompt && !removed) || !onChange) return;
    const edit: QueueEdit = removed
      ? { op: "update", text: next, images: kept.map((image) => image.id) }
      : { op: "update", text: next };
    const generation = (saveGeneration.current.get(entry.id) ?? 0) + 1;
    saveGeneration.current.set(entry.id, generation);
    const latest = () => saveGeneration.current.get(entry.id) === generation;
    savesPending.current.set(entry.id, (savesPending.current.get(entry.id) ?? 0) + 1);
    // A refused edit (acpmux answered no: the prompt already started) hands the typed text back to
    // the composer. A call that failed before acpmux could have it (not connected, a typed
    // refusal) leaves the row queued, so the text goes back into the row's editor: restoring it to
    // the composer too would show the prompt twice. If the row is gone by the time the queue next
    // draws, the open editor hands the text back then. A timeout or a closed bridge may have
    // reached acpmux already: the next snapshot says, and restoring could duplicate it.
    void onChange(entry.id, edit).then(
      (ok) => {
        settleSave(entry.id);
        // A superseded Save's answer is stale: the newer one's text is the one that counts.
        if (!ok && latest()) onLost?.(next, entry.id);
      },
      (error: unknown) => {
        settleSave(entry.id);
        if (mayHaveReachedAcpmux(error) || !latest()) return;
        // Another edit is open (or a sibling's recovery just claimed the editor in this batch): its
        // draft is not ours to drop, so this text waits its turn and the row stays queued meanwhile.
        if (editingNow.current !== undefined || leavingNow.current.has(entry.id)) {
          recovered.current.set(entry.id, { text: next, original: entry.prompt, generation });
          return;
        }
        editingNow.current = entry.id;
        draft.current = { id: entry.id, original: entry.prompt, text: next };
        setEditing(entry.id);
      },
    );
  };
  const rowKeyDown = (event: React.KeyboardEvent<HTMLElement>, entry: QueuedEntry, index: number) => {
    if (event.target !== event.currentTarget) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    // A teammate's prompt is theirs to change (acpmux `queue.not_author`): its row only walks.
    const mine = !theirs(entry);
    const done = () => {
      event.preventDefault();
      event.stopPropagation();
    };
    if (event.key === "Enter" && event.metaKey) {
      // ⌘↩ on a row does nothing: Send now is a click (above). It would send the prompt from the
      // composer otherwise.
      done();
    } else if (event.key === "Enter" && plain && onChange && mine) {
      done();
      setEditing(entry.id);
    } else if ((event.key === "ArrowUp" || event.key === "ArrowDown") && event.altKey && move && mine) {
      done();
      move(entry, index + (event.key === "ArrowUp" ? -1 : 1));
    } else if ((event.key === "ArrowUp" || event.key === "ArrowDown") && plain) {
      done();
      focusRow(index + (event.key === "ArrowUp" ? -1 : 1));
    } else if ((event.key === "Delete" || event.key === "Backspace") && plain && remove && mine) {
      done();
      remove(entry);
      focusAfter(index);
    } else if (event.key === "Escape" && plain) {
      done();
      onLeave?.();
    }
  };
  // The fold's own keys: ↑ to the last row shown, ↓ and Esc to the prompt; Return and Space are
  // the button's.
  const foldKeyDown = (event: React.KeyboardEvent<HTMLElement>) => {
    if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown" && event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    if (event.key === "ArrowUp") focusRow(visible.length - 1);
    else onLeave?.();
  };
  // The row's menu names each action's key on the row.
  const item = (id: string, label: string, key: string, onSelect: () => void): ContextMenuItem => ({
    id,
    ariaLabel: label,
    label: (
      <>
        {label}
        <span className="ui-menu-shortcut">{key}</span>
      </>
    ),
    onSelect,
  });
  const menu = (entry: QueuedEntry, index: number): ContextMenuItem[] =>
    theirs(entry)
      ? []
      : whileOwnersHold([
          ...(canSendNow(entry)
            ? [
                {
                  id: "steer",
                  ariaLabel: t("composer.queueSteer"),
                  label: t("composer.queueSteer"),
                  onSelect: () => sendNow?.(entry),
                },
              ]
            : []),
          ...(onChange ? [item("edit", t("composer.queueEditMessage"), "↩", () => setEditing(entry.id))] : []),
          ...(move
            ? [
                {
                  ...item("up", t("composer.queueMoveUp"), "⌥↑", () => move(entry, index - 1)),
                  disabled: moveTarget(entry, index - 1) === undefined,
                  separatorBefore: true,
                },
                {
                  ...item("down", t("composer.queueMoveDown"), "⌥↓", () => move(entry, index + 1)),
                  disabled: moveTarget(entry, index + 1) === undefined,
                },
              ]
            : []),
          ...(remove
            ? [
                {
                  ...item("delete", t("composer.queueDelete"), "⌫", () => remove(entry)),
                  destructive: true,
                  separatorBefore: true,
                },
              ]
            : []),
        ]);
  // The row's actions, as ChatGPT and Codex show them: Steer (a glyph and its word), the trash can
  // (an icon named by its tooltip), and the ⋯ menu. Plain glyphs: a soft pill on hover only.
  const actions = (entry: QueuedEntry) => {
    if (theirs(entry)) return null;
    const side = sideChat?.(entry);
    return (
      <span className="acpmux-queued-actions">
        {canSendNow(entry) && (
          <button
            type="button"
            className="acpmux-queued-action acpmux-queued-steer"
            data-action="steer"
            aria-label={t("composer.queueSteer")}
            onClick={() => sendNow?.(entry)}
          >
            <Icon name="composer.steer" size={14} />
            <span>{t("composer.queueSteer")}</span>
          </button>
        )}
        {cancelEdit && (
          <button
            type="button"
            className="acpmux-queued-action"
            data-action="cancel-edit"
            aria-label={t("message.edit")}
            title={t("message.edit")}
            onClick={() => void cancelEdit(entry)}
          >
            <Icon name="action.close" size={14} />
          </button>
        )}
        {remove && (
          <button
            type="button"
            className="acpmux-queued-action"
            data-action="delete"
            aria-label={t("composer.queueDelete")}
            title={t("composer.queueDelete")}
            onClick={() => remove(entry)}
          >
            <Icon name="action.delete" size={14} />
          </button>
        )}
        <Menu>
          <MenuButton
            className="acpmux-queued-action"
            data-menu="queued-more"
            label={t("composer.queueActions")}
            title={t("composer.queueActions")}
            aria-haspopup="menu"
          >
            <Icon name="action.more" size={14} />
          </MenuButton>
          <MenuPopup
            side="top"
            align="end"
            className="acpmux-quick-menu acpmux-queued-more"
            label={t("composer.queueActions")}
          >
            {onChange && (
              <MenuItem className="acpmux-quick-item" shortcut="↩" onSelect={() => setEditing(entry.id)}>
                {t("composer.queueEditMessage")}
              </MenuItem>
            )}
            {side && (
              <MenuItem className="acpmux-quick-item" onSelect={side}>
                {t("composer.queueSideChat")}
              </MenuItem>
            )}
            <MenuItem className="acpmux-quick-item" onSelect={() => setQueueing(!queueing)}>
              {t(queueing ? "composer.queueingOff" : "composer.queueingOn")}
            </MenuItem>
          </MenuPopup>
        </Menu>
      </span>
    );
  };
  // A row's text (or its edit) and actions. A prompt sent now says "Steering" ahead of its text; a
  // queued one keeps "Queued" for assistive tech only.
  const cells = (entry: QueuedEntry, index: number) => (
    <>
      {!entry.next && <span className="acpmux-hidden-label">{t("composer.queued")}</span>}
      {editing === entry.id ? (
        <QueuedEdit
          entry={entry}
          label={t("composer.queueEdit")}
          initial={draft.current?.id === entry.id ? draft.current.text : withoutSkillDollars(entry.prompt, skills)}
          onInput={(text) => (draft.current = { id: entry.id, original: entry.prompt, text })}
          onDone={(text) => (text === undefined ? cancel(index) : save(entry, text))}
        />
      ) : (
        <button
          type="button"
          className="acpmux-queued-text"
          data-open={open.has(entry.id) ? "" : undefined}
          aria-expanded={open.has(entry.id)}
          onPointerEnter={(event) => titleWhenTruncated(event, shownText(entry, t, skills))}
          onPointerDown={(event) => (pressedBy.current = event.pointerType)}
          onClick={(event) => {
            // A mouse or pen press is a hovering pointer; a key (no press) or a touch is none.
            const by = pressedBy.current;
            pressedBy.current = undefined;
            toggle(entry.id, event.detail > 0 && (by === "mouse" || by === "pen"));
          }}
        >
          {/* WebKit does not clamp a button's own lines: the clamp is on its text. */}
          <span className="acpmux-queued-clamp">
            {entry.author && <AuthorChip author={entry.author} inline />}
            {entry.next && (
              <span className="acpmux-queued-kind" data-kind="steer">
                {t("composer.steering")}
              </span>
            )}
            {entry.retry ? (
              <>
                <span className="acpmux-queued-kind" data-kind="retry">
                  {t("composer.queuedSubagentRetry")}
                </span>
                {entry.retry.name ?? entry.retry.agentId}
                {open.has(entry.id) && entry.retry.error && (
                  <span className="acpmux-queued-detail">{entry.retry.error}</span>
                )}
              </>
            ) : (
              withoutSkillDollars(entry.prompt, skills)
            )}
          </span>
        </button>
      )}
      {editing !== entry.id && actions(entry)}
      {/* Under the text, in its column. */}
      <QueuedImages
        images={
          editing === entry.id ? (entry.images ?? []).filter((image) => !dropped.has(image.id)) : (entry.images ?? [])
        }
        t={t}
        read={readImage}
        onRemove={editing === entry.id ? (id) => setDropped((current) => new Set(current).add(id)) : undefined}
        onLeave={
          editing === entry.id
            ? () => save(entry, draft.current?.id === entry.id ? draft.current.text : entry.prompt)
            : undefined
        }
        onCancel={editing === entry.id ? () => cancel(index) : undefined}
      />
    </>
  );
  return (
    <>
      <ol
        ref={list}
        className="ui-glass ui-glass-floats acpmux-composer-queue"
        data-unfolded={foldable && !folded ? "" : undefined}
        // The prompts the fold hides, still queued: the transcript keeps no room for them as it
        // does for a card that leaves (VirtualTranscript `noteQueue`).
        data-folded-ids={
          folded
            ? shown
                .slice(visible.length)
                .map((entry) => entry.id)
                .join(" ")
            : undefined
        }
        // A row that takes focus from the keyboard (keys, a move, ↑ from the prompt) scrolls in whole.
        onFocus={(event) => {
          const row = (event.target as HTMLElement).closest("li");
          if (row && list.current && !pressing.current) reveal(list.current, row);
        }}
        onPointerLeave={(event) => {
          if (held.current) release(event.currentTarget);
        }}
        onPointerDown={(event) => {
          pressing.current = true;
          // Released anywhere, over the list or not; a press that ends outside the page (a
          // native menu, the window losing focus) or before a key ends there too.
          const page = event.currentTarget.ownerDocument;
          const ended = new AbortController();
          const done = () => {
            pressing.current = false;
            ended.abort();
          };
          const options = { capture: true, signal: ended.signal };
          for (const type of ["pointerup", "pointercancel", "keydown"]) page.addEventListener(type, done, options);
          // Not capturing: a capturing window listener also hears the blur of whatever had focus.
          page.defaultView?.addEventListener("blur", done, { signal: ended.signal });
        }}
        aria-label={`${t("composer.queue")} (${shown.length})`}
      >
        {paused && (
          <li className="acpmux-queue-paused">
            <span
              // tooltip-allow: a long error is cut to the row; its whole text is the tooltip
              title={pauseReason}
            >
              {pauseReason ? t("composer.queuePausedWhy", { error: pauseReason }) : t("composer.queuePaused")}
            </span>
            {onChange && (
              <button
                type="button"
                className="acpmux-queue-resume"
                onClick={() => void onChange(queue[0].id, { op: "resume" }).catch(() => undefined)}
              >
                {t("composer.queueResume")}
              </button>
            )}
          </li>
        )}
        {/* One flat keyed list: a row keeps its element (and focus) when a row before it leaves. */}
        {visible.map((entry, index) => (
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- A row takes focus from ↑ on the prompt and has its keys (edit, move, send now, remove); its buttons do the same by pointer.
          <li
            className="acpmux-queued"
            key={entry.id}
            data-prompt-id={entry.id}
            aria-keyshortcuts={theirs(entry) ? undefined : "Enter Alt+ArrowUp Alt+ArrowDown Delete"}
            {...rovingTabStopProps(false, (event) => rowKeyDown(event, entry, index))}
          >
            {editing === entry.id ? (
              cells(entry, index)
            ) : (
              <ContextMenu className="acpmux-queued-menu" items={menu(entry, index)}>
                {cells(entry, index)}
              </ContextMenu>
            )}
          </li>
        ))}
      </ol>
      {/* The fold sits under the list, outside its scrolling, so no row ever runs under it. */}
      {foldable && (
        <div className="ui-glass ui-glass-floats acpmux-queue-foldbar">
          <button
            ref={foldButton}
            type="button"
            className="acpmux-queue-fold"
            aria-expanded={!folded}
            {...rovingTabStopProps(true, foldKeyDown)}
            onClick={() => unfold(folded)}
          >
            {folded ? t("composer.queueMore", { n: shown.length - visible.length }) : t("composer.queueLess")}
          </button>
        </div>
      )}
    </>
  );
}

/// A queued prompt's text, edited in its row: Return saves (it keeps its place), Shift-Return adds
/// a line, Esc cancels. A textarea, so a prompt's lines stay lines.
function QueuedEdit({
  entry,
  label,
  initial,
  onInput,
  onDone,
}: {
  entry: QueuedEntry;
  label: string;
  /// The text the editor opens with when it comes back after a failed save; the row's own otherwise.
  initial?: string;
  onInput(text: string): void;
  /// The new text, or undefined when cancelled.
  onDone(text: string | undefined): void;
}) {
  const input = useRef<HTMLTextAreaElement>(null);
  const finished = useRef(false);
  const finish = (text: string | undefined) => {
    if (finished.current) return;
    finished.current = true;
    onDone(text);
  };
  // As tall as its lines.
  const fit = () => {
    const field = input.current;
    if (!field) return;
    field.style.height = "auto";
    field.style.height = `${field.scrollHeight}px`;
  };
  useEffect(() => {
    input.current?.focus();
    input.current?.select();
    fit();
  }, []);
  return (
    <textarea
      ref={input}
      className="acpmux-queued-edit"
      aria-label={label}
      rows={1}
      defaultValue={initial ?? entry.prompt}
      onInput={(event) => {
        fit();
        onInput(event.currentTarget.value);
      }}
      // ui-allow: the edit field's own editing keys (Return saves, Shift-Return adds a line, Esc cancels).
      onKeyDown={(event) => {
        // Every key belongs to the input method while it composes (WebKit sends its Return as 229).
        if (event.nativeEvent.isComposing || event.keyCode === 229) return;
        if ((event.key === "Enter" && !event.shiftKey) || event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          finish(event.key === "Enter" ? event.currentTarget.value : undefined);
        }
      }}
      // A click elsewhere saves; leaving the window keeps the edit open, and so does Tab to the
      // prompt's image remove controls (QueuedImages.tsx), which save when focus leaves them.
      onBlur={(event) => {
        const to = event.relatedTarget;
        const images = event.currentTarget.parentElement?.querySelector(".acpmux-queued-images");
        if (to instanceof Node && images?.contains(to)) return;
        if (to || document.hasFocus()) finish(event.currentTarget.value);
      }}
    />
  );
}
