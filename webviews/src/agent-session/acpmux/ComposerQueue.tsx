// Prompts waiting for the running turn, as compact rows attached to the composer's top edge. The
// list is laid over the transcript's foot, not in the layout, so a prompt being queued, sent or
// removed never moves the composer or the transcript.
//
// Keyboard first: ↑ on an empty prompt goes to the last row; on a row, ↑/↓ move between rows (↓
// past the last goes back to the prompt), Return edits it in place, ⌥↑/⌥↓ move it in the queue,
// ⌘Return sends it now and Delete removes it. Esc goes back to the prompt.
import React, { useEffect, useRef, useState } from "react";
import { Icon } from "./icons/Icon";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import type { Translate } from "./i18n";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";

type QueuedEntry = AcpmuxSnapshot["queue"][number];

/** Shows the full prompt as a tooltip only when its one line is cut off. */
function titleWhenTruncated(event: React.PointerEvent<HTMLElement>, prompt: string) {
  const text = event.currentTarget;
  if (text.scrollWidth > text.clientWidth) text.title = prompt;
  else text.removeAttribute("title");
}

export function ComposerQueue({
  queue,
  t,
  onRemove,
  onChange,
  onLost,
  onLeave,
}: {
  queue: AcpmuxSnapshot["queue"];
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
  const list = useRef<HTMLOListElement>(null);
  useEffect(() => {
    setLeaving((current) => {
      const kept = [...current].filter((id) => queue.some((entry) => entry.id === id));
      return kept.length === current.size ? current : new Set(kept);
    });
    if (editing && !queue.some((entry) => entry.id === editing)) setEditing(undefined);
  }, [queue, editing]);
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
  // A move keeps focus on the moved row once acpmux's new order draws.
  const move =
    onChange &&
    ((entry: QueuedEntry, index: number) => {
      if (index < 0 || index >= shown.length) return;
      void onChange(entry.id, { op: "move", index }).then(() =>
        requestAnimationFrame(() =>
          list.current?.querySelector<HTMLElement>(`[data-prompt-id="${entry.id}"]`)?.focus(),
        ),
      );
    });
  const save = (entry: QueuedEntry, text: string) => {
    setEditing(undefined);
    focusRow(shown.indexOf(entry));
    const next = text.trim();
    if (!next || next === entry.prompt || !onChange) return;
    void onChange(entry.id, { op: "update", text: next }).then((ok) => {
      if (!ok) onLost?.(next);
    });
  };
  const rowKeyDown = (event: React.KeyboardEvent<HTMLLIElement>, entry: QueuedEntry, index: number) => {
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
  const menu = (entry: QueuedEntry, index: number): ContextMenuItem[] => [
    ...(sendNow ? [{ id: "send", label: t("composer.queueSendNow"), onSelect: () => sendNow(entry) }] : []),
    ...(onChange ? [{ id: "edit", label: t("composer.queueEdit"), onSelect: () => setEditing(entry.id) }] : []),
    ...(move
      ? [
          {
            id: "up",
            label: t("composer.queueMoveUp"),
            disabled: index === 0,
            separatorBefore: true,
            onSelect: () => move(entry, index - 1),
          },
          {
            id: "down",
            label: t("composer.queueMoveDown"),
            disabled: index === shown.length - 1,
            onSelect: () => move(entry, index + 1),
          },
        ]
      : []),
    ...(remove
      ? [
          {
            id: "remove",
            label: t("composer.queueRemove"),
            destructive: true,
            separatorBefore: true,
            onSelect: () => remove(entry),
          },
        ]
      : []),
  ];
  return (
    <ol ref={list} className="acpmux-composer-queue" aria-label={`${t("composer.queue")} (${shown.length})`}>
      {shown.map((entry, index) => (
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- A row takes focus from ↑ on the prompt and has its keys (edit, move, send now, remove); its buttons do the same by pointer.
        <li
          className="acpmux-queued"
          key={entry.id}
          data-prompt-id={entry.id}
          tabIndex={-1}
          title={editing === entry.id ? undefined : t("composer.queueRowHint")}
          onKeyDown={(event) => rowKeyDown(event, entry, index)}
        >
          <ContextMenu className="acpmux-queued-menu" items={menu(entry, index)}>
            <span className="acpmux-queued-mark" aria-hidden="true">
              {index + 1}
            </span>
            <span className="acpmux-hidden-label">{t("composer.queued")}</span>
            {editing === entry.id ? (
              <QueuedEdit
                entry={entry}
                label={t("composer.queueEdit")}
                onDone={(text) => {
                  if (text !== undefined) return save(entry, text);
                  setEditing(undefined);
                  focusRow(index);
                }}
              />
            ) : (
              <span className="acpmux-queued-text" onPointerEnter={(event) => titleWhenTruncated(event, entry.prompt)}>
                {entry.prompt}
              </span>
            )}
            {editing !== entry.id && (sendNow || onChange || remove) && (
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
                {onChange && (
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
                {remove && (
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
          </ContextMenu>
        </li>
      ))}
    </ol>
  );
}

/// A queued prompt's text, edited in its row: Return saves (it keeps its place), Esc cancels.
function QueuedEdit({
  entry,
  label,
  onDone,
}: {
  entry: QueuedEntry;
  label: string;
  /// The new text, or undefined when cancelled.
  onDone(text: string | undefined): void;
}) {
  const input = useRef<HTMLInputElement>(null);
  const finished = useRef(false);
  const finish = (text: string | undefined) => {
    if (finished.current) return;
    finished.current = true;
    onDone(text);
  };
  useEffect(() => {
    input.current?.focus();
    input.current?.select();
  }, []);
  return (
    <input
      ref={input}
      className="acpmux-queued-edit"
      aria-label={label}
      defaultValue={entry.prompt}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing) return;
        if (event.key === "Enter" || event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          finish(event.key === "Enter" ? event.currentTarget.value : undefined);
        }
      }}
      onBlur={(event) => finish(event.currentTarget.value)}
    />
  );
}
