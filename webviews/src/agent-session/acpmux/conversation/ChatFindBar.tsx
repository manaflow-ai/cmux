// Find in Chat's bar (chatFind.ts): the query, where the reader is among the matches, and the
// steps. Enter and Cmd-G go to the next match, Shift-Enter and Shift-Cmd-G to the previous one,
// Escape closes the bar.
import { useEffect, useRef } from "react";
import { useT } from "../i18n";
import type { ChatFind } from "./chatFind";

export function ChatFindBar({ find }: { find: ChatFind }) {
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
          aria-label={t("find.placeholder")}
          placeholder={t("find.placeholder")}
          value={find.query}
          spellCheck={false}
          onChange={(event) => find.setQuery(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <span className="acpmux-find__count" aria-live="polite">
          {status}
        </span>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.previous")}
          title={t("find.previous")}
          disabled={!count}
          onClick={find.previous}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <path
              d="M2.5 7.5 6 4l3.5 3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.next")}
          title={t("find.next")}
          disabled={!count}
          onClick={find.next}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <path
              d="M2.5 4.5 6 8l3.5-3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
        <button
          type="button"
          className="acpmux-find__step"
          aria-label={t("find.close")}
          title={t("find.close")}
          onClick={find.hide}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
            <path d="m3.5 3.5 5 5m0-5-5 5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          </svg>
        </button>
      </div>
    </search>
  );
}
