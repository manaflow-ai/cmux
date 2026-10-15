// Prompts waiting for the running turn, as compact rows over the composer. The list takes its own
// place at the top of the composer form, over its location strip, so the transcript, a question
// waiting for an answer and the pull requests above the composer each keep theirs: none is cut
// off or drawn over, and the transcript scrolls in what is left.
//
// Keyboard first: ↑ on an empty prompt goes to the last row; on a row, ↑/↓ move between rows (↓
// past the last goes back to the prompt), Return edits it in place, ⌥↑/⌥↓ move it in the queue,
// ⌘Return sends it now and Delete removes it. Esc goes back to the prompt.
//
// After a failed turn acpmux pauses the queue: a note above the rows says so, with Resume.
//
// A long queue folds (Leo, 2026-10-14): past three queued prompts it shows the next two and one
// "N more queued" row, which opens the whole list in place and closes it back ("Show less"). The
// fold is a button (aria-expanded) under the list, outside its scrolling, so ↑ from the prompt
// reaches it first and no row runs under it. Opened, the list keeps about its folded height and
// scrolls whole rows (composerStates.css), so the chat above moves one row at most. It stays open
// for its chat until closed (not across reloads); prompts sent now always show.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Icon } from "./icons/Icon";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import type { Translate } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { experimentArm } from "../../experiments/experiment";
import { hoverActions } from "../../ui/hoverActions.experiment";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/** A queue of more queued prompts than this folds; folded, it shows `FOLD_SHOWS` of them. */
const FOLD_AT = 3;
const FOLD_SHOWS = 2;
/** The chats whose long queue is open, for this page's life. */
const openQueues = new Set<string>();

// The list rests on whole rows (captures of 436917b and f1a737b, 2026-10-15). Its height is the
// bottom of the last row that fits under its cap: the CSS cap folded, the third row's bottom opened
// (so opening moves the chat above by about a row, whatever the rows' heights), and opening lands at
// its top. A row that takes focus scrolls in whole, its "Queued" header with it at the top; a row
// the edge cuts while the list scrolls still draws (a blank slot read as a missing prompt).

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
  // The header and the next prompt always show whole, even one opened past the cap.
  if (rows[0]) cap = Math.max(cap, ends[items.indexOf(rows[0])]);
  const fit = ends.filter((end) => end <= cap + 0.5).at(-1) ?? cap;
  const height = `${fit}px`;
  if (list.style.maxHeight !== height) list.style.maxHeight = height;
}

/** Scrolls the list so `row` shows whole, starting at a row's top (its header's, for the first). */
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

/** Shows the full prompt as a tooltip only when its two lines (the button's inner text) cut it off. */
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
  t,
  onRemove,
  onChange,
  onLost,
  onLeave,
}: {
  queue: AcpmuxSnapshot["queue"];
  /// The chat the queue belongs to: a long queue opened stays open for it.
  chat?: string;
  /// A turn failed and the queue waits for Resume (acpmux `queuePaused`).
  paused?: boolean;
  t: Translate;
  /// Withdraws a waiting prompt; false when it already started (it then leaves with the turn).
  onRemove?(id: string): Promise<boolean>;
  /// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
  onChange?(id: string, edit: QueueEdit): Promise<boolean>;
  /// An edit of a prompt that started meanwhile: its text goes back to the prompt, so it is kept.
  onLost?(text: string): void;
  /// Focus leaves the queue for the prompt.
  onLeave?(): void;
}) {
  // A row leaves as soon as it is removed; it comes back only if acpmux kept it waiting.
  const [leaving, setLeaving] = useState<ReadonlySet<string>>(new Set());
  const [editing, setEditing] = useState<string>();
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
  useEffect(() => {
    setLeaving((current) => {
      const kept = [...current].filter((id) => queue.some((entry) => entry.id === id));
      return kept.length === current.size ? current : new Set(kept);
    });
    if (editing && !queue.some((entry) => entry.id === editing)) {
      const open = draft.current;
      if (open?.id === editing && open.text.trim() && open.text !== open.original) onLost?.(open.text.trim());
      draft.current = undefined;
      setEditing(undefined);
    }
  }, [queue, editing, onLost]);
  // Whole rows only: the list's height, after every draw and when its width changes.
  const watched = useRef<{ list: HTMLElement; observer: ResizeObserver }>(undefined);
  const wasOpen = useRef(unfolded);
  useLayoutEffect(() => {
    const current = list.current;
    if (current) fitList(current);
    // Opening lands at the top: the header and the next prompt (row snapping kept it on row 2).
    if (current && unfolded && !wasOpen.current) current.scrollTop = 0;
    wasOpen.current = unfolded;
    if (watched.current?.list !== current) {
      watched.current?.observer.disconnect();
      watched.current = undefined;
      if (current && typeof ResizeObserver !== "undefined") {
        let width = current.clientWidth;
        const observer = new ResizeObserver(() => {
          if (current.clientWidth === width) return;
          width = current.clientWidth;
          fitList(current);
        });
        observer.observe(current);
        watched.current = { list: current, observer };
      }
    }
  });
  useEffect(() => () => watched.current?.observer.disconnect(), []);
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
  const shown = queue.filter((entry) => !leaving.has(entry.id));
  if (shown.length === 0) return null;
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
  // A prompt sent now stays in place: acpmux marks it next (`queue_order`), so its row reads
  // Steering until it runs; to an agent that steers it leaves once acpmux takes it (`dequeued`).
  // Hiding it as leaving showed nothing until the turn it stopped had ended (live run 2026-10-14).
  const sendNow =
    onChange && ((entry: QueuedEntry) => void onChange(entry.id, { op: "send_now" }).catch(() => undefined));
  const allActions = experimentArm(hoverActions) === "all";
  // A move to the place of the row shown at `index` (acpmux counts rows still leaving too); the
  // moved row keeps focus once acpmux's new order draws.
  const move =
    onChange &&
    ((entry: QueuedEntry, index: number) => {
      const to = shown[index] && queue.findIndex((q) => q.id === shown[index].id);
      if (to === undefined || to < 0) return;
      // A move into the folded part opens the queue, so the moved row stays in sight.
      if (folded && index >= visible.length) unfold(true);
      refocus.current = entry.id;
      void onChange(entry.id, { op: "move", index: to }).finally(() =>
        setTimeout(() => {
          if (refocus.current === entry.id) refocus.current = undefined;
        }, 500),
      );
    });
  const save = (entry: QueuedEntry, text: string) => {
    draft.current = undefined;
    setEditing(undefined);
    focusRow(shown.indexOf(entry));
    const next = text.trim();
    if (!next || next === entry.prompt || !onChange) return;
    void onChange(entry.id, { op: "update", text: next }).then((ok) => {
      if (!ok) onLost?.(next);
    });
  };
  const rowKeyDown = (event: React.KeyboardEvent<HTMLElement>, entry: QueuedEntry, index: number) => {
    if (event.target !== event.currentTarget) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    const done = () => {
      event.preventDefault();
      event.stopPropagation();
    };
    if (event.key === "Enter" && event.metaKey && sendNow) {
      done();
      sendNow(entry);
      focusAfter(index);
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
    ...(sendNow ? [item("send", t("composer.queueSendNow"), "⌘↩", () => sendNow(entry))] : []),
    ...(onChange ? [item("edit", t("composer.queueEdit"), "↩", () => setEditing(entry.id))] : []),
    ...(move
      ? [
          {
            ...item("up", t("composer.queueMoveUp"), "⌥↑", () => move(entry, index - 1)),
            disabled: index === 0,
            separatorBefore: true,
          },
          {
            ...item("down", t("composer.queueMoveDown"), "⌥↓", () => move(entry, index + 1)),
            disabled: index === shown.length - 1,
          },
        ]
      : []),
    ...(remove
      ? [
          {
            ...item("remove", t("composer.queueRemove"), "⌫", () => remove(entry)),
            destructive: true,
            separatorBefore: true,
          },
        ]
      : []),
  ];
  // A row's mark, text (or its edit) and actions.
  const cells = (entry: QueuedEntry, index: number) => (
    <>
      {/* A prompt sent now keeps the narrow mark column (its send glyph) and says "Steering" ahead of
          its text: a label in the mark column widened it for every row (round-4 captures). */}
      {entry.next ? (
        <span className="acpmux-queued-mark" data-kind="steer" aria-hidden="true">
          <Icon name="composer.send" size={12} />
        </span>
      ) : (
        <>
          <span className="acpmux-queued-mark" aria-hidden="true">
            {index + 1 - steering}
          </span>
          <span className="acpmux-hidden-label">{t("composer.queued")}</span>
        </>
      )}
      {editing === entry.id ? (
        <QueuedEdit
          entry={entry}
          label={t("composer.queueEdit")}
          onInput={(text) => (draft.current = { id: entry.id, original: entry.prompt, text })}
          onDone={(text) => {
            if (text !== undefined) return save(entry, text);
            draft.current = undefined;
            setEditing(undefined);
            focusRow(index);
          }}
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
      {/* Send now is the row's one hover action; Edit and Remove are on its menu and keys (Leo dogfood
          2026-10-13). The `hover-actions` experiment's "all" arm shows them too. */}
      {editing !== entry.id && (sendNow || (allActions && (onChange || remove))) && (
        <span className="acpmux-queued-actions">
          {sendNow && (
            <button
              type="button"
              className="acpmux-queued-action"
              aria-label={t("composer.queueSendNow")}
              title={t("composer.queueSendNow")}
              onClick={() => sendNow(entry)}
            >
              <Icon name="composer.send" size={14} />
            </button>
          )}
          {onChange && allActions && (
            <button
              type="button"
              className="acpmux-queued-action"
              aria-label={t("composer.queueEdit")}
              title={t("composer.queueEdit")}
              onClick={() => setEditing(entry.id)}
            >
              <Icon name="action.edit" size={14} />
            </button>
          )}
          {remove && allActions && (
            <button
              type="button"
              className="acpmux-queued-action"
              aria-label={t("composer.queueRemove")}
              title={t("composer.queueRemove")}
              onClick={() => remove(entry)}
            >
              <Icon name="action.delete" size={14} />
            </button>
          )}
        </span>
      )}
    </>
  );
  return (
    <>
      <ol
        ref={list}
        className="acpmux-composer-queue"
        data-unfolded={foldable && !folded ? "" : undefined}
        // A row that takes focus (keys, a move, ↑ from the prompt) scrolls in whole.
        onFocus={(event) => {
          const row = (event.target as HTMLElement).closest("li");
          if (row && list.current) reveal(list.current, row);
        }}
        aria-label={`${t("composer.queue")} (${shown.length})`}
      >
        {paused && (
          <li className="acpmux-queue-paused">
            <span>{t("composer.queuePaused")}</span>
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
        {visible.flatMap((entry, index) => [
          // "Queued" heads the prompts that wait for the turn, under any sent now.
          index === steering && (
            <li key="queued" className="acpmux-queue-header" aria-hidden="true">
              <span className="acpmux-queued-kind">{t("composer.queued")}</span>
              <span>{t("composer.queueAfterTurn")}</span>
            </li>
          ),
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- A row takes focus from ↑ on the prompt and has its keys (edit, move, send now, remove); its buttons do the same by pointer.
          <li
            className="acpmux-queued"
            key={entry.id}
            data-prompt-id={entry.id}
            aria-keyshortcuts="Enter Alt+ArrowUp Alt+ArrowDown Meta+Enter Delete"
            {...rovingTabStopProps(false, (event) => rowKeyDown(event, entry, index))}
          >
            {editing === entry.id ? (
              cells(entry, index)
            ) : (
              <ContextMenu className="acpmux-queued-menu" items={menu(entry, index)}>
                {cells(entry, index)}
              </ContextMenu>
            )}
          </li>,
        ])}
      </ol>
      {/* The fold sits under the list, outside its scrolling, so no row ever runs under it. */}
      {foldable && (
        <div className="acpmux-queue-foldbar">
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
      // A click elsewhere saves; leaving the window keeps the edit open.
      onBlur={(event) => {
        if (document.hasFocus()) finish(event.currentTarget.value);
      }}
    />
  );
}
