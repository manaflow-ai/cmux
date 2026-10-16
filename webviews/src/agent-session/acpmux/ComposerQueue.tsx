// Prompts waiting for the running turn, as compact rows attached to the composer's top edge. The
// list sits in space reserved above the composer, keeping every preceding status and permission
// row clear while the composer remains anchored at the bottom of the pane.
//
// Keyboard first: ↑ on an empty prompt goes to the last row; on a row, ↑/↓ move between rows (↓
// past the last goes back to the prompt), Return edits it in place, ⌥↑/⌥↓ move it in the queue,
// ⌘Return sends it now and Delete removes it. Esc goes back to the prompt.
//
// After a failed turn acpmux pauses the queue: a note above the rows says so, with Resume.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Icon } from "./icons/Icon";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import type { Translate } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { experimentArm } from "../../experiments/experiment";
import { hoverActions } from "../../ui/hoverActions.experiment";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/** Shows the full prompt as a tooltip only when its one line is cut off. */
function titleWhenTruncated(event: React.PointerEvent<HTMLElement>, prompt: string) {
  const text = event.currentTarget;
  if (text.scrollWidth > text.clientWidth) text.title = prompt;
  else text.removeAttribute("title");
}

export function ComposerQueue({
  queue,
  paused,
  t,
  onRemove,
  onChange,
  onLost,
  onLeave,
}: {
  queue: AcpmuxSnapshot["queue"];
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
  // A row leaves as soon as it is removed or sent; it comes back only if acpmux kept it waiting.
  const [leaving, setLeaving] = useState<ReadonlySet<string>>(new Set());
  const [editing, setEditing] = useState<string>();
  // What the open edit holds now: a prompt that starts while it is edited hands it to the prompt.
  const draft = useRef<{ id: string; original: string; text: string }>(undefined);
  // The row a move keeps focus on, once the new order draws.
  const refocus = useRef<string>(undefined);
  const list = useRef<HTMLOListElement>(null);
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
  useLayoutEffect(() => {
    const id = refocus.current;
    const row = id ? list.current?.querySelector<HTMLElement>(`[data-prompt-id="${id}"]`) : null;
    if (row && document.activeElement !== row) row.focus();
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

  const rows = () => [...(list.current?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? [])];
  const focusRow = (index: number) => {
    const all = rows();
    if (index >= all.length) onLeave?.();
    else all[Math.max(0, index)]?.focus();
  };
  const remove = onRemove && ((entry: QueuedEntry) => act(entry.id, () => onRemove(entry.id)));
  const sendNow = onChange && ((entry: QueuedEntry) => act(entry.id, () => onChange(entry.id, { op: "send_now" })));
  const allActions = experimentArm(hoverActions) === "all";
  // A move to the place of the row shown at `index` (acpmux counts rows still leaving too); the
  // moved row keeps focus once acpmux's new order draws.
  const move =
    onChange &&
    ((entry: QueuedEntry, index: number) => {
      const to = shown[index] && queue.findIndex((q) => q.id === shown[index].id);
      if (to === undefined || to < 0) return;
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
      focusRow(index + 1);
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
      focusRow(index + 1);
    } else if (event.key === "Escape" && plain) {
      done();
      onLeave?.();
    }
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
      <span className="acpmux-queued-mark" aria-hidden="true">
        {index + 1}
      </span>
      <span className="acpmux-hidden-label">{t("composer.queued")}</span>
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
        <span className="acpmux-queued-text" onPointerEnter={(event) => titleWhenTruncated(event, entry.prompt)}>
          {entry.prompt}
        </span>
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
    <ol ref={list} className="acpmux-composer-queue" aria-label={`${t("composer.queue")} (${shown.length})`}>
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
      {shown.map((entry, index) => (
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
        </li>
      ))}
    </ol>
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
