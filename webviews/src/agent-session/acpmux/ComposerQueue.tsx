// Prompts waiting for the running turn, as compact rows attached to the composer's top edge. The
// list is laid over the transcript's foot, not in the layout, so a prompt being queued, sent or
// removed never moves the composer or the transcript.
import React from "react";
import type { AcpmuxSnapshot } from "./model";
import type { Translate } from "./i18n";

/** Shows the full prompt as a tooltip only when its one line is cut off. */
function titleWhenTruncated(event: React.PointerEvent<HTMLElement>, prompt: string) {
  const text = event.currentTarget;
  if (text.scrollWidth > text.clientWidth) text.title = prompt;
  else text.removeAttribute("title");
}

export function ComposerQueue({ queue, t }: { queue: AcpmuxSnapshot["queue"]; t: Translate }) {
  if (queue.length === 0) return null;
  return (
    <ol className="acpmux-composer-queue" aria-label={t("composer.queue")}>
      {queue.map((entry, index) => (
        <li className="acpmux-queued" key={entry.id}>
          <span className="acpmux-queued-mark" aria-hidden="true">
            {index + 1}
          </span>
          <span className="acpmux-hidden-label">{t("composer.queued")}</span>
          <span className="acpmux-queued-text" onPointerEnter={(event) => titleWhenTruncated(event, entry.prompt)}>
            {entry.prompt}
          </span>
        </li>
      ))}
    </ol>
  );
}
