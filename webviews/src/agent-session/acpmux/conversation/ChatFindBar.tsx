// Find in Chat's bar (chatFind.ts): the shared find pill (ui/FindPill.tsx, the web twin of the
// native one) with the query, where the reader is among the matches, and the steps. Enter and
// Cmd-G go to the next match, Shift-Enter and Shift-Cmd-G to the previous one, Escape closes.
import { useEffect, useRef } from "react";
import { FindPill, type FindPillIconRole } from "../../../ui/FindPill";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { FindBarState } from "./chatFind";

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
      <div className="acpmux-find__bar">
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
