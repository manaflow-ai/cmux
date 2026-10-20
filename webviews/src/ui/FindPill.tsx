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
  return (
    <search
      id={ids?.root}
      className={props.className ? `find-pill ${props.className}` : "find-pill"}
      aria-label={labels.placeholder}
    >
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
            title={labels.matchCase}
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
    </search>
  );
}
