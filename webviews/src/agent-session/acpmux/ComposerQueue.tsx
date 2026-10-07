// Prompts waiting for the running turn, as compact rows attached to the composer's top edge. The
// list is laid over the transcript's foot, not in the layout, so a prompt being queued, sent or
// removed never moves the composer or the transcript. Its box is a fixed, click-through height
// with the rows packed at the bottom, so a row leaving moves neither the list nor the rows below.
import React, { useEffect, useState } from "react";
import { Icon } from "./icons/Icon";
import type { AcpmuxSnapshot } from "./model";
import type { Translate } from "./i18n";

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
  onEdit,
}: {
  queue: AcpmuxSnapshot["queue"];
  t: Translate;
  /// Withdraws a waiting prompt; false when it already started (it then leaves with the turn).
  onRemove?(id: string): Promise<boolean>;
  /// Withdraws a waiting prompt and puts its text back in the composer.
  onEdit?(entry: QueuedEntry): Promise<boolean>;
}) {
  // A row leaves as soon as it is acted on; it comes back only if acpmux kept the prompt waiting.
  const [leaving, setLeaving] = useState<ReadonlySet<string>>(new Set());
  useEffect(() => {
    setLeaving((current) => {
      const kept = [...current].filter((id) => queue.some((entry) => entry.id === id));
      return kept.length === current.size ? current : new Set(kept);
    });
  }, [queue]);
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
  return (
    <ol className="acpmux-composer-queue" aria-label={t("composer.queue")}>
      {shown.map((entry, index) => (
        <li className="acpmux-queued" key={entry.id}>
          <span className="acpmux-queued-mark" aria-hidden="true">
            {index + 1}
          </span>
          <span className="acpmux-hidden-label">{t("composer.queued")}</span>
          <span className="acpmux-queued-text" onPointerEnter={(event) => titleWhenTruncated(event, entry.prompt)}>
            {entry.prompt}
          </span>
          {(onEdit || onRemove) && (
            <span className="acpmux-queued-actions">
              {onEdit && (
                <button
                  type="button"
                  className="acpmux-queued-action"
                  aria-label={t("composer.queueEdit")}
                  title={t("composer.queueEdit")}
                  onClick={() => act(entry.id, () => onEdit(entry))}
                >
                  <Icon name="action.edit" size={14} />
                </button>
              )}
              {onRemove && (
                <button
                  type="button"
                  className="acpmux-queued-action"
                  aria-label={t("composer.queueRemove")}
                  title={t("composer.queueRemove")}
                  onClick={() => act(entry.id, () => onRemove(entry.id))}
                >
                  <Icon name="action.delete" size={14} />
                </button>
              )}
            </span>
          )}
        </li>
      ))}
    </ol>
  );
}
