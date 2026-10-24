// The code editor's Cmd-F bar: the shared find pill (ui/FindPill.tsx) over Monaco's top right,
// where every pane's find pill sits, driven by EditorFind. Monaco's own find widget never shows.
import { lazy, Suspense, useCallback, useEffect, useRef, useSyncExternalStore } from "react";
import type { FindPillProps } from "../../ui/FindPill";
import type { Strings } from "../shared/i18n";
import type { EditorFind } from "./editorFind";
import { L } from "./strings";

// Cmd-F is the only path that renders this control. Keep the pill out of the editor's first-load
// closure; the editor can paint its file before a user asks for search, then fetch this small chunk
// when the find state opens.
const ICONS = { search: "search", previous: "chevronUp", next: "chevronDown", close: "close" } as const;

const LazyFindPill = lazy(async () => {
  const [{ FindPill }, { Icon }] = await Promise.all([import("../../ui/FindPill"), import("../../icons")]);
  const EditorFindPill = (props: Omit<FindPillProps, "icon">) => (
    <FindPill {...props} icon={(role) => <Icon name={ICONS[role]} />} />
  );
  return { default: EditorFindPill };
});

export function EditorFindBar({ find, strings }: { find: EditorFind; strings: Strings }) {
  const state = useSyncExternalStore(find.subscribe, find.getState);
  const field = useRef<HTMLInputElement>(null);
  const setField = useCallback(
    (node: HTMLInputElement | null) => {
      field.current = node;
      if (node && state.open) {
        node.focus();
        node.select();
      }
    },
    [state.open],
  );
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
      <Suspense fallback={null}>
        <LazyFindPill
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
          inputRef={setField}
          labels={{
            placeholder: t(L.findPlaceholder),
            previous: t(L.findPrevious),
            next: t(L.findNext),
            close: t(L.findClose),
            matchCase: t(L.findMatchCase),
          }}
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
      </Suspense>
    </div>
  );
}
