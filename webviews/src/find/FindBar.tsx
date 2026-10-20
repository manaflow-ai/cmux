import { useEffect, useRef } from "react";
import { Icon } from "../icons";
import type { DiffViewerLabelResolver } from "../labels";
import type { DiffFindController } from "./useDiffFind";

type FindBarProps = {
  controller: DiffFindController;
  label: DiffViewerLabelResolver;
  query: string;
  /** Increments on every open/refocus request (Cmd+F, native forward). */
  requestToken: number;
};

/**
 * The diff viewer's find-in-page bar. Rendered inside the `#viewer` scroll
 * container as a sticky overlay; mounting it installs the highlight painter
 * through `controller.findBarRef`.
 */
export function FindBar({ controller, label, query, requestToken }: FindBarProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);

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

  const onInputKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      if (event.shiftKey) {
        controller.goToPrevious();
      } else {
        controller.goToNext();
      }
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      controller.closeFind();
    }
  };

  return (
    <div id="diff-find-anchor" ref={controller.findBarRef}>
      <search id="diff-find-bar" aria-label={label("findInDiff")}>
        <input
          ref={inputRef}
          id="diff-find-input"
          type="text"
          value={query}
          placeholder={label("findInDiff")}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          aria-label={label("findInDiff")}
          onChange={(event) => controller.setQuery(event.target.value)}
          onKeyDown={onInputKeyDown}
        />
        {hasQuery ? (
          <span id="diff-find-count" aria-live="polite">{current}/{total}</span>
        ) : null}
        <button
          type="button"
          className="toolbar-icon"
          aria-label={label("findPreviousMatch")}
          title={label("findPreviousMatch")}
          disabled={total === 0}
          onClick={controller.goToPrevious}
        >
          <Icon name="chevronUp" />
        </button>
        <button
          type="button"
          className="toolbar-icon"
          aria-label={label("findNextMatch")}
          title={label("findNextMatch")}
          disabled={total === 0}
          onClick={controller.goToNext}
        >
          <Icon name="chevronDown" />
        </button>
        <button
          type="button"
          className="toolbar-icon"
          aria-label={label("findClose")}
          title={label("findClose")}
          onClick={controller.closeFind}
        >
          <Icon name="close" />
        </button>
      </search>
    </div>
  );
}
