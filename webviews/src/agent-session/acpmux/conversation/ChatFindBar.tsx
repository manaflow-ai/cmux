// Find in Chat's bar (chatFind.ts): the query, where the reader is among the matches, and the
// steps. Enter and Cmd-G go to the next match, Shift-Enter and Shift-Cmd-G to the previous one,
// Escape closes the bar.
import { useEffect, useRef } from "react";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { FindBarState } from "./chatFind";

/** `label` names the field (its placeholder too); Find in Chat by default. */
export function ChatFindBar({ find, label }: { find: FindBarState; label?: string }) {
  const t = useT();
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => {
    field.current?.focus();
    field.current?.select();
  }, [find.focusRequest]);
  const count = find.matches.length;
  const status = !find.query
    ? ""
    : count
      ? t("find.count", { current: find.active + 1, total: count })
      : t("find.noResults");
  const onKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    // Candidate acceptance/cancellation belongs to the IME. WebKit can report only 229 on commit.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const step = event.key === "Enter" || (event.metaKey && event.key.toLowerCase() === "g");
    if (step) {
      event.preventDefault();
      if (event.shiftKey) find.previous();
      else find.next();
    } else if (event.key === "Escape") {
      event.preventDefault();
      find.hide();
    }
  };
  return (
    <search className="acpmux-find">
      <div className="acpmux-find__bar">
        <input
          ref={field}
          className="acpmux-find__field"
          type="search"
          aria-label={label ?? t("find.placeholder")}
          placeholder={label ?? t("find.placeholder")}
          value={find.query}
          spellCheck={false}
          onChange={(event) => find.setQuery(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <span className="acpmux-find__count" aria-live="polite" data-empty={find.query && !count ? "" : undefined}>
          {status}
        </span>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.previous")}
          title={`${t("find.previous")} (⇧↩)`}
          disabled={!count}
          onClick={find.previous}
        >
          <Icon name="disclosure.expanded" size={14} className="acpmux-find__up" />
        </button>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.next")}
          title={`${t("find.next")} (↩)`}
          disabled={!count}
          onClick={find.next}
        >
          <Icon name="disclosure.expanded" size={14} />
        </button>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.close")}
          title={`${t("find.close")} (Esc)`}
          onClick={find.hide}
        >
          <Icon name="action.close" size={14} />
        </button>
      </div>
    </search>
  );
}
