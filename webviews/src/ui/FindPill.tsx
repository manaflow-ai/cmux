// The find pill: the web twin of the native FindPillView (CmuxNextDesign/FindPill), so every
// Cmd-F bar in a page (Find in Chat, Find in Diff) is the same Liquid Glass capsule as the
// terminal's and the browser's (findPill.css carries FindPillMetrics' numbers). It only draws and
// reports; its surface owns the search. Enter and Cmd-G step to the next match, Shift-Enter and
// Shift-Cmd-G to the previous one, Escape closes; an IME composition keeps its own keys.
import type { KeyboardEvent, ReactNode, Ref } from "react";
import "./findPill.css";

/** The icons a pill draws, from the host's icon set (the native pill's four). */
export type FindPillIconRole = "search" | "previous" | "next" | "close";

export type FindPillLabels = {
  /** The field's placeholder and accessible name. */
  placeholder: string;
  previous: string;
  next: string;
  close: string;
  /** The match-case toggle's name; absent where the search cannot match case (no toggle). */
  matchCase?: string;
};

/** The replace row (the code editor's Replace, Opt-Cmd-F). */
export type FindPillReplace = {
  /** The row shows. */
  open: boolean;
  value: string;
  onChange: (value: string) => void;
  onReplace: () => void;
  onReplaceAll: () => void;
  /** The chevron before the field shows or hides the row; absent: no chevron. */
  onToggle?: () => void;
  labels: { field: string; replace: string; replaceAll: string; toggle: string };
  inputRef?: Ref<HTMLInputElement>;
};

export type FindPillProps = {
  query: string;
  onQueryChange: (query: string) => void;
  /** "2 of 3", "No matches", or empty while there is no query. */
  status: string;
  /** Nothing matched: the status reads in the danger ink. */
  noMatches: boolean;
  /** The chevrons work (something matched). */
  canStep: boolean;
  onNext: () => void;
  onPrevious: () => void;
  onClose: () => void;
  labels: FindPillLabels;
  icon: (role: FindPillIconRole) => ReactNode;
  matchCase?: boolean;
  onMatchCaseChange?: (matchCase: boolean) => void;
  inputRef?: Ref<HTMLInputElement>;
  /** Cmd-G in the field steps (default); false where a document-level handler already does. */
  commandGSteps?: boolean;
  /** Where the search can also replace (the code editor). */
  replace?: FindPillReplace;
  /** Ids kept for callers that address the parts (tests, keyboard scopes). */
  ids?: { root?: string; field?: string; count?: string };
  className?: string;
};

export function FindPill(props: FindPillProps) {
  const { labels, icon, ids } = props;
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    // Candidate acceptance/cancellation belongs to the IME. WebKit can report only 229 on commit.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const commandG = props.commandGSteps !== false && event.metaKey && event.key.toLowerCase() === "g";
    const step = event.key === "Enter" || commandG;
    if (step) {
      event.preventDefault();
      if (event.shiftKey) props.onPrevious();
      else props.onNext();
    } else if (event.key === "Escape") {
      event.preventDefault();
      props.onClose();
    }
  };
  const toggles = labels.matchCase !== undefined && props.onMatchCaseChange !== undefined;
  const replace = props.replace;
  const toggle = replace?.onToggle ? (
    <button
      type="button"
      className="find-pill__button find-pill__toggle"
      aria-label={replace.labels.toggle}
      title={replace.labels.toggle}
      aria-expanded={replace.open}
      onClick={replace.onToggle}
    >
      {icon(replace.open ? "next" : "previous")}
    </button>
  ) : null;
  const findRow = (
    <>
      <span className="find-pill__icon" aria-hidden="true">
        {icon("search")}
      </span>
      <input
        ref={props.inputRef}
        id={ids?.field}
        className="find-pill__field"
        type="search"
        value={props.query}
        placeholder={labels.placeholder}
        aria-label={labels.placeholder}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        onChange={(event) => props.onQueryChange(event.target.value)}
        onKeyDown={onKeyDown}
      />
      <span
        id={ids?.count}
        className="find-pill__count"
        aria-live="polite"
        data-none={props.noMatches ? "" : undefined}
      >
        {props.status}
      </span>
      <span className="find-pill__separator" aria-hidden="true" />
      {toggles ? (
        <>
          <button
            type="button"
            className="find-pill__button find-pill__button--text"
            aria-label={labels.matchCase}
            aria-pressed={props.matchCase ? "true" : "false"}
            onClick={() => props.onMatchCaseChange?.(!props.matchCase)}
          >
            Aa
          </button>
          <span className="find-pill__separator" aria-hidden="true" />
        </>
      ) : null}
      <button
        type="button"
        className="find-pill__button"
        aria-label={labels.previous}
        title={`${labels.previous} (⇧↩)`}
        disabled={!props.canStep}
        onClick={props.onPrevious}
      >
        {icon("previous")}
      </button>
      <button
        type="button"
        className="find-pill__button"
        aria-label={labels.next}
        title={`${labels.next} (↩)`}
        disabled={!props.canStep}
        onClick={props.onNext}
      >
        {icon("next")}
      </button>
      <button
        type="button"
        className="find-pill__button"
        aria-label={labels.close}
        title={`${labels.close} (Esc)`}
        onClick={props.onClose}
      >
        {icon("close")}
      </button>
    </>
  );
  const onReplaceKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (event.key === "Enter") {
      event.preventDefault();
      if (event.metaKey || event.altKey) replace?.onReplaceAll();
      else replace?.onReplace();
    } else if (event.key === "Escape") {
      event.preventDefault();
      props.onClose();
    }
  };
  const rootClass = ["find-pill", replace?.open ? "find-pill--replace" : "", props.className ?? ""]
    .filter(Boolean)
    .join(" ");
  return (
    <search id={ids?.root} className={rootClass} aria-label={labels.placeholder}>
      {replace ? (
        <>
          <div className="find-pill__row">
            {toggle}
            {findRow}
          </div>
          {replace.open ? (
            <div className="find-pill__row find-pill__replace">
              <input
                ref={replace.inputRef}
                className="find-pill__field"
                type="text"
                value={replace.value}
                placeholder={replace.labels.field}
                aria-label={replace.labels.field}
                autoComplete="off"
                autoCorrect="off"
                autoCapitalize="off"
                spellCheck={false}
                onChange={(event) => replace.onChange(event.target.value)}
                onKeyDown={onReplaceKeyDown}
              />
              <button
                type="button"
                className="find-pill__button find-pill__button--text find-pill__replace-one"
                disabled={!props.canStep}
                onClick={replace.onReplace}
              >
                {replace.labels.replace}
              </button>
              <button
                type="button"
                className="find-pill__button find-pill__button--text find-pill__replace-all"
                disabled={!props.canStep}
                onClick={replace.onReplaceAll}
              >
                {replace.labels.replaceAll}
              </button>
            </div>
          ) : null}
        </>
      ) : (
        findRow
      )}
    </search>
  );
}
