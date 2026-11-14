// Find in Chat's bar (chatFind.ts): the shared find pill (ui/FindPill.tsx, the web twin of the
// native one) with the query, where the reader is among the matches, and the steps. Enter and
// Cmd-G go to the next match, Shift-Enter and Shift-Cmd-G to the previous one, Escape closes.
import { useEffect, useLayoutEffect, useRef } from "react";
import { FindPill, type FindPillIconRole } from "../../../ui/FindPill";
import { setPopupInsetTop } from "../../../ui/popupInset";
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

/** The room kept between the bar and a popup that flips below it. */
const POPUP_CLEARANCE = 4;

/** `label` names the field (its placeholder too); Find in Chat by default. */
export function ChatFindBar({ find, label }: { find: FindBarState; label?: string }) {
  const t = useT();
  const field = useRef<HTMLInputElement>(null);
  const bar = useRef<HTMLDivElement>(null);
  // The bar is the top layer of its pane: while it shows, tooltips and hover cards keep below it,
  // flipping under their row instead of covering it (ui/popupInset.ts; Leo 2026-11-07: "we don't want
  // it to be coverable by other sorts of things. Like, for example, these hover previews").
  useLayoutEffect(() => {
    const node = bar.current;
    if (!node) return;
    const view = node.ownerDocument.defaultView;
    const place = () => setPopupInsetTop(node.getBoundingClientRect().bottom + POPUP_CLEARANCE, "findBar");
    place();
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(place) : undefined;
    observer?.observe(node);
    view?.addEventListener("resize", place);
    return () => {
      observer?.disconnect();
      view?.removeEventListener("resize", place);
      setPopupInsetTop(0, "findBar");
    };
  }, []);
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
