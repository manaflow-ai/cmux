// Find in Chat's bar (chatFind.ts): the shared find pill (ui/FindPill.tsx, the web twin of the
// native one) with the query, where the reader is among the matches, and the steps. Enter and
// Cmd-G go to the next match, Shift-Enter and Shift-Cmd-G to the previous one, Escape closes.
import { useEffect, useLayoutEffect, useRef } from "react";
import { FindPill, type FindPillIconRole } from "../../../ui/FindPill";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { FIND_HIDE_EVENT, FIND_OPEN_EVENT, type FindBarState } from "./chatFind";

/** The native pill's icons (FindPillIcons in the browser and terminal). */
const ICONS: Record<FindPillIconRole, string> = {
  search: "browser.omnibox.search",
  previous: "browser.find.previous",
  next: "browser.find.next",
  close: "action.close",
};

/** `label` names the field (its placeholder too); Find in Chat by default. */
export function ChatFindBar({ find, label }: { find: FindBarState; label?: string }) {
  const t = useT();
  const field = useRef<HTMLInputElement>(null);
  // Opening, it tells the pane, so a Session Info with no room for the bar beside it steps aside; the
  // pane closes it when the person opens Session Info over it there.
  const { hide } = find;
  useEffect(() => {
    const shell = field.current?.closest(".acpmux-shell");
    shell?.dispatchEvent(new (shell.ownerDocument.defaultView?.Event ?? Event)(FIND_OPEN_EVENT));
  }, []);
  useEffect(() => {
    const shell = field.current?.closest(".acpmux-shell");
    shell?.addEventListener(FIND_HIDE_EVENT, hide);
    return () => shell?.removeEventListener(FIND_HIDE_EVENT, hide);
  }, [hide]);
  // The transcript keeps its top fade while the bar is open, with full ink over the bar's box
  // (conversation.css: --acpmux-find-x, --acpmux-find-y and --acpmux-find-width on the scroller),
  // measured before paint and again when the bar narrows, the pane resizes, or Session Info moves it
  // (its reach is a style on the shell, SessionInfo.tsx SESSION_INFO_CLEAR).
  const bar = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = bar.current;
    const scroller = node?.closest<HTMLElement>(".acpmux-scroll");
    const View = node?.ownerDocument.defaultView;
    if (!node || !scroller || !View) return;
    const measure = () => {
      const box = node.getBoundingClientRect();
      const view = scroller.getBoundingClientRect();
      scroller.style.setProperty("--acpmux-find-x", `${box.left - view.left}px`);
      scroller.style.setProperty("--acpmux-find-y", `${box.top - view.top}px`);
      scroller.style.setProperty("--acpmux-find-width", `${box.width}px`);
    };
    measure();
    const observer = new View.ResizeObserver(measure);
    observer.observe(node);
    observer.observe(scroller);
    const shell = scroller.closest(".acpmux-shell");
    const moved = new View.MutationObserver(measure);
    if (shell) moved.observe(shell, { attributes: true, attributeFilter: ["style"] });
    return () => {
      observer.disconnect();
      moved.disconnect();
      scroller.style.removeProperty("--acpmux-find-x");
      scroller.style.removeProperty("--acpmux-find-y");
      scroller.style.removeProperty("--acpmux-find-width");
    };
  }, []);
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
  return (
    <div className="acpmux-find">
      <div className="acpmux-find__bar" ref={bar}>
        <FindPill
          query={find.query}
          onQueryChange={find.setQuery}
          status={status}
          noMatches={Boolean(find.query) && !count}
          canStep={count > 0}
          onNext={find.next}
          onPrevious={find.previous}
          onClose={find.hide}
          inputRef={field}
          labels={{
            placeholder: label ?? t("find.placeholder"),
            previous: t("find.previous"),
            next: t("find.next"),
            close: t("find.close"),
          }}
          icon={(role) => <Icon name={ICONS[role]} size={14} />}
        />
      </div>
    </div>
  );
}
