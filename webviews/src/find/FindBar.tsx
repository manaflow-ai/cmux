import { lazy, Suspense, useCallback, useEffect, useRef } from "react";
import type { FindPillIconRole, FindPillProps } from "../ui/FindPill";
import type { DiffViewerLabelResolver } from "../labels";
import type { DiffFindController } from "./useDiffFind";

type FindBarProps = {
  controller: DiffFindController;
  label: DiffViewerLabelResolver;
  query: string;
  /** Increments on every open/refocus request (Cmd+F, native forward). */
  requestToken: number;
};

/** The native pill's roles in the viewer's icon set. */
const ICONS = {
  search: "search",
  previous: "chevronUp",
  next: "chevronDown",
  close: "close",
} as const satisfies Record<FindPillIconRole, string>;

// The find bar is hidden until Cmd-F. Keep its pill and icon set out of the diff page's first-load
// closure, then fetch them when the bar mounts.
const LazyFindPill = lazy(async () => {
  const [{ FindPill }, { Icon }] = await Promise.all([import("../ui/FindPill"), import("../icons")]);
  const DiffFindPill = (props: Omit<FindPillProps, "icon">) => (
    <FindPill {...props} icon={(role) => <Icon name={ICONS[role]} />} />
  );
  return { default: DiffFindPill };
});

/** Gallery-only warm-up: the production diff page still loads the pill on first Cmd-F. */
export async function preloadFindBar(): Promise<void> {
  await Promise.all([import("../ui/FindPill"), import("../icons")]);
}

/**
 * The diff viewer's find-in-page bar: the shared find pill (ui/FindPill.tsx). Rendered inside the `#viewer` scroll
 * container as a sticky overlay; mounting it installs the highlight painter
 * through `controller.findBarRef`.
 */
export function FindBar({ controller, label, query, requestToken }: FindBarProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const setInputRef = useCallback(
    (node: HTMLInputElement | null) => {
      inputRef.current = node;
      if (node && requestToken > 0) {
        node.focus();
        node.select();
      }
    },
    [requestToken],
  );

  // Focus and select the query on every open/refocus request. Selecting lets
  // a recovered previous query be typed over immediately.
  useEffect(() => {
    if (requestToken > 0) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [requestToken]);

  const hasQuery = query !== "";
  const total = controller.matches.length;
  const current = total === 0 ? 0 : controller.activeIndex + 1;
  const status = !hasQuery
    ? ""
    : total === 0
      ? label("findNoMatches")
      : label("findCount").replace("{current}", String(current)).replace("{total}", String(total));

  return (
    <div id="diff-find-anchor" ref={controller.findBarRef}>
      <Suspense fallback={null}>
        <LazyFindPill
          query={query}
          onQueryChange={controller.setQuery}
          status={status}
          noMatches={hasQuery && total === 0}
          canStep={total > 0}
          onNext={controller.goToNext}
          onPrevious={controller.goToPrevious}
          onClose={controller.closeFind}
          inputRef={setInputRef}
          commandGSteps={false}
          ids={{ root: "diff-find-bar", field: "diff-find-input", count: "diff-find-count" }}
          labels={{
            placeholder: label("findInDiff"),
            previous: label("findPreviousMatch"),
            next: label("findNextMatch"),
            close: label("findClose"),
          }}
        />
      </Suspense>
    </div>
  );
}
