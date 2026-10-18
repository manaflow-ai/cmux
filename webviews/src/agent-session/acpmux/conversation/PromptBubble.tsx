import { useContext, useLayoutEffect, useRef, useState } from "react";
import type { AcpmuxRow } from "../model";
import { useT } from "../i18n";
import { usePromptFindReveal } from "./chatFind";
import { MessageTime } from "./MessageTime";
import { expandPrompt, PROMPT_LINES, PromptToggleAnchor, usePromptExpanded } from "./promptCollapse";
import { ChatSessionContext } from "./viewIdentity";

/// Lab bubble: eight lines until opened, measured again when its width changes (Lucas 2026-10-18).
export function PromptBubble({
  row,
  text,
  collapse,
  times,
}: {
  row: AcpmuxRow;
  text: string;
  collapse: boolean;
  times: boolean;
}) {
  const t = useT();
  const sessionId = useContext(ChatSessionContext);
  const anchorToggle = useContext(PromptToggleAnchor);
  const open = usePromptExpanded(row.id, sessionId);
  const content = useRef<HTMLDivElement>(null);
  const [long, setLong] = useState(false);
  usePromptFindReveal(row, collapse);
  useLayoutEffect(() => {
    const element = content.current;
    if (!collapse || !element) return;
    const measure = () => {
      const height = Number.parseFloat(getComputedStyle(element).lineHeight) || 22.75;
      setLong(element.scrollHeight > PROMPT_LINES * height + 1);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [collapse, text]);
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- ui-allow: focus reveals the prompt's send time
    <div className="cv-user__bubble selectable cv-user__bubble--labs" tabIndex={times ? 0 : undefined}>
      {collapse ? (
        <>
          <div ref={content} className={`cv-user__prompt${!open ? " is-clamped" : ""}${long ? " is-long" : ""}`}>
            {text}
          </div>
          {long && (
            <button
              type="button"
              className="cv-user__expand"
              aria-expanded={open}
              data-find-skip
              onClick={(event) => {
                anchorToggle?.(event.currentTarget);
                expandPrompt(row.id, !open, sessionId);
              }}
            >
              {open ? t("shell.showLess") : t("sidebar.showMore")}
            </button>
          )}
        </>
      ) : (
        text
      )}
      {times && <MessageTime at={row.at} />}
    </div>
  );
}
