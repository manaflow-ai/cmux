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
import { ownQueue, queuedAttachments } from "./conversation/queuedMessages";
import { setQueueing, useQueueing } from "./queueing";

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

/** Shows the full prompt as a tooltip only when its one line (the button's inner text) cuts it off. */
function titleWhenTruncated(event: React.PointerEvent<HTMLElement>, prompt: string) {
  const button = event.currentTarget;
  const text = button.firstElementChild ?? button;
  if (text.scrollWidth > text.clientWidth || text.scrollHeight > text.clientHeight + 1) button.title = prompt;
  else button.removeAttribute("title");
}

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
}) {
  // A row leaves as soon as it is removed; it comes back only if acpmux kept it waiting.
  const [leaving, setLeaving] = useState<ReadonlySet<string>>(new Set());
  // A successful Send now is reflected by acpmux's next snapshot, but the action must disappear
  // immediately after the queue_edit reply so a second click cannot resend it.
  const [sentNow, setSentNow] = useState<ReadonlySet<string>>(new Set());
  const queueing = useQueueing();
  const [editing, setEditingId] = useState<string>();
  // The images the open edit drops from its prompt.
  const [dropped, setDropped] = useState<ReadonlySet<string>>(new Set());
  const setEditing = (id: string | undefined) => {
    setDropped(new Set());
    setEditingId(id);
  };
  // Rows opened to their whole text (a row shows two lines until it is opened).
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  const toggle = (id: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  // What the open edit holds now: a prompt that starts while it is edited hands it to the prompt.
  const draft = useRef<{ id: string; original: string; text: string }>(undefined);
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
    if (editing && !queue.some((entry) => entry.id === editing)) {
      const open = draft.current;
      if (open?.id === editing && open.text.trim() && open.text !== open.original) onLost?.(open.text.trim(), editing);
      draft.current = undefined;
      setDropped(new Set());
      setEditingId(undefined);
    }
  }, [queue, editing, onLost]);
  // Whole rows only: the list's height, after every draw, when its width changes, and when a row's
  // height does (a prompt opened to its whole text, its images read).
  const watched = useRef<{ list: HTMLElement; observer: ResizeObserver; rows: ResizeObserver }>(undefined);
  const fitReadyFrame = useRef<number | undefined>(undefined);
  const wasOpen = useRef(unfolded);
  useLayoutEffect(() => {
    const current = list.current;
    if (current) {
      const firstFit = !current.hasAttribute("data-fit-ready");
      fitList(current);
      if (firstFit) {
        fitReadyFrame.current = requestFitFrame(current.ownerDocument, () => {
          fitReadyFrame.current = undefined;
          if (current.isConnected) current.setAttribute("data-fit-ready", "");
        });
      }
    }
    // Opening lands at the top: the header and the next prompt.
    if (current && unfolded && !wasOpen.current) current.scrollTop = 0;
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
          fitList(current);
        });
        observer.observe(current);
        const rows = new ResizeObserver(() => fitList(current));
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
  const cancelEdit =
    onCancelEdit &&
    (async (entry: QueuedEntry) => {
      const attachments = await queuedAttachments(entry.images, readImage);
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
  const move =
    onChange &&
    ((entry: QueuedEntry, index: number) => {
      const target = shown[index];
      const from = queueIndex(entry);
      const to = target ? queueIndex(target) : from + (index < shown.indexOf(entry) ? -1 : 1);
      if (from < 0 || to < 0 || to >= queue.length) return;
      // A move into the folded part opens the queue, so the moved row stays in sight.
      if (folded && index >= visible.length) unfold(true);
      refocus.current = entry.id;
      void onChange(entry.id, { op: "move", index: to }).finally(() =>
        setTimeout(() => {
          if (refocus.current === entry.id) refocus.current = undefined;
        }, 500),
      );
    });
  // The open edit ends unsaved, its images all kept; focus goes back to its row.
  const cancel = (index: number) => {
    draft.current = undefined;
    setEditing(undefined);
    focusRow(index);
  };
  const save = (entry: QueuedEntry, text: string) => {
    const images = entry.images ?? [];
    const kept = images.filter((image) => !dropped.has(image.id));
    draft.current = undefined;
    setEditing(undefined);
    focusRow(shown.indexOf(entry));
    const next = text.trim();
    // Text alone keeps every image; an image removed sends the ones left.
    const removed = kept.length < images.length;
    if (!next || (next === entry.prompt && !removed) || !onChange) return;
    const edit: QueueEdit = removed
      ? { op: "update", text: next, images: kept.map((image) => image.id) }
      : { op: "update", text: next };
    void onChange(entry.id, edit).then((ok) => {
      if (!ok) onLost?.(next, entry.id);
    });
  };
  const rowKeyDown = (event: React.KeyboardEvent<HTMLElement>, entry: QueuedEntry, index: number) => {
    if (event.target !== event.currentTarget) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    const done = () => {
      event.preventDefault();
      event.stopPropagation();
    };
    if (event.key === "Enter" && event.metaKey) {
      // ⌘↩ on a row does nothing: Send now is a click (above). It would send the prompt from the
      // composer otherwise.
      done();
    } else if (event.key === "Enter" && plain && onChange) {
      done();
      setEditing(entry.id);
    } else if ((event.key === "ArrowUp" || event.key === "ArrowDown") && event.altKey && move) {
      done();
      move(entry, index + (event.key === "ArrowUp" ? -1 : 1));
    } else if ((event.key === "ArrowUp" || event.key === "ArrowDown") && plain) {
      done();
      focusRow(index + (event.key === "ArrowUp" ? -1 : 1));
    } else if ((event.key === "Delete" || event.key === "Backspace") && plain && remove) {
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
  const menu = (entry: QueuedEntry, index: number): ContextMenuItem[] => [
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
            disabled: queueIndex(entry) <= 0,
            separatorBefore: true,
          },
          {
            ...item("down", t("composer.queueMoveDown"), "⌥↓", () => move(entry, index + 1)),
            disabled: queueIndex(entry) === queue.length - 1,
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
  ];
  // The row's actions, as ChatGPT and Codex show them: Steer (a glyph and its word), the trash can
  // (an icon named by its tooltip), and the ⋯ menu. Plain glyphs: a soft pill on hover only.
  const actions = (entry: QueuedEntry) => {
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
          onInput={(text) => (draft.current = { id: entry.id, original: entry.prompt, text })}
          onDone={(text) => (text === undefined ? cancel(index) : save(entry, text))}
        />
      ) : (
        <button
          type="button"
          className="acpmux-queued-text"
          data-open={open.has(entry.id) ? "" : undefined}
          aria-expanded={open.has(entry.id)}
          onPointerEnter={(event) => titleWhenTruncated(event, entry.prompt)}
          onClick={() => toggle(entry.id)}
        >
          {/* WebKit does not clamp a button's own lines: the clamp is on its text. */}
          <span className="acpmux-queued-clamp">
            {entry.next && (
              <span className="acpmux-queued-kind" data-kind="steer">
                {t("composer.steering")}
              </span>
            )}
            {entry.prompt}
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
                onClick={() => void onChange(queue[0].id, { op: "resume" })}
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
            aria-keyshortcuts="Enter Alt+ArrowUp Alt+ArrowDown Delete"
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
  onInput,
  onDone,
}: {
  entry: QueuedEntry;
  label: string;
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
      defaultValue={entry.prompt}
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
