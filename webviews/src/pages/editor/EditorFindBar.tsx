// The code editor's Cmd-F bar: the shared find pill (ui/FindPill.tsx) over Monaco's top right,
// where every pane's find pill sits, driven by EditorFind. Monaco's own find widget never shows.
import { useEffect, useRef, useSyncExternalStore } from "react";
import { Icon } from "../../icons";
import { FindPill } from "../../ui/FindPill";
import type { Strings } from "../shared/i18n";
import type { EditorFind } from "./editorFind";
import { L } from "./strings";

/** The same icons as the diff viewer's pill. */
const ICONS = { search: "search", previous: "chevronUp", next: "chevronDown", close: "close" } as const;

export function EditorFindBar({ find, strings }: { find: EditorFind; strings: Strings }) {
  const state = useSyncExternalStore(find.subscribe, find.getState);
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!state.open) return;
    field.current?.focus();
    field.current?.select();
  }, [state.open, state.focusRequest]);
  if (!state.open) return null;
  const { t } = strings;
  const count = state.matches.length;
  const status = !state.query
    ? ""
    : count
      ? strings.format(L.findCount, String(state.active + 1), String(count))
      : t(L.findNoMatches);
  return (
    <div className="ed-find">
      <FindPill
        query={state.query}
        onQueryChange={find.setQuery}
        status={status}
        noMatches={Boolean(state.query) && count === 0}
        canStep={count > 0}
        onNext={find.next}
        onPrevious={find.previous}
        onClose={find.hide}
        matchCase={state.matchCase}
        onMatchCaseChange={find.setMatchCase}
        inputRef={field}
        labels={{
          placeholder: t(L.findPlaceholder),
          previous: t(L.findPrevious),
          next: t(L.findNext),
          close: t(L.findClose),
          matchCase: t(L.findMatchCase),
        }}
        icon={(role) => <Icon name={ICONS[role]} />}
        replace={{
          open: state.replaceOpen,
          value: state.replacement,
          onChange: find.setReplacement,
          onReplace: find.replace,
          onReplaceAll: find.replaceAll,
          onToggle: find.toggleReplace,
          labels: {
            field: t(L.findReplaceWith),
            replace: t(L.findReplace),
            replaceAll: t(L.findReplaceAll),
            toggle: t(L.findToggleReplace),
          },
        }}
      />
    </div>
  );
}
