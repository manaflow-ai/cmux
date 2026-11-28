// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import { Icon, type IconName } from "../icons";
import { FindPill, type FindPillIconRole } from "./FindPill";

type Props = {
  noMatches?: boolean;
  selected?: boolean;
  replace?: boolean;
  /** Terminal history find: whole-word and regex toggles, a streaming count, an inline pattern error. */
  terminal?: "idle" | "streaming" | "invalid" | "toggles";
  /** The pill's glass (RFD 0207; ui/findGlass.experiment.ts): `page` ships; `host`, behind experiments.findGlass
   *  (off by default), the App's transient glass under the page. A browser gallery has no App, so the two
   *  look alike here: the App's capture shows them. */
  glass?: "page" | "host";
  /** Transcript-like text under the pill. */
  busy?: boolean;
};
const BUSY_TEXT =
  "Read 14 files in webviews/src/ui. The find pill steps through the matches and keeps the count beside the " +
  "field; the transcript under it keeps scrolling while the pill stays legible over it. ".repeat(4);
const icons = {
  search: "search",
  previous: "chevronUp",
  next: "chevronDown",
  close: "close",
} as const satisfies Record<FindPillIconRole, IconName>;

function FindFixture({ noMatches = false, selected = false, replace = false, terminal, glass = "page", busy = false }: Props) {
  const [query, setQuery] = useState("needle");
  const [matchCase, setMatchCase] = useState(selected);
  const [replacement, setReplacement] = useState("replacement");
  const [replaceOpen, setReplaceOpen] = useState(replace);
  const [index, setIndex] = useState(1);
  const [wholeWord, setWholeWord] = useState(terminal === "toggles");
  const [regex, setRegex] = useState(terminal === "toggles" || terminal === "invalid");
  const invalid = terminal === "invalid";
  const status =
    terminal === "idle"
      ? ""
      : terminal === "streaming"
        ? "3 of 1,204+"
        : invalid
          ? "Invalid pattern"
          : noMatches
            ? "No matches"
            : `${index} of 3`;
  return (
    <div style={{ padding: 24, position: "relative" }}>
      {busy && (
        <p aria-hidden="true" style={{ position: "absolute", inset: 0, margin: 0, padding: 8, opacity: 0.8 }}>
          {BUSY_TEXT}
        </p>
      )}
      <FindPill
        hostGlass={glass === "host"}
        query={terminal === "idle" ? "" : invalid ? "(unclosed" : query}
        onQueryChange={setQuery}
        status={status}
        noMatches={noMatches || invalid}
        canStep={!noMatches && !invalid && terminal !== "idle"}
        onNext={() => setIndex((value) => (value % 3) + 1)}
        onPrevious={() => setIndex((value) => ((value + 1) % 3) + 1)}
        onClose={() => setQuery("")}
        matchCase={matchCase}
        onMatchCaseChange={setMatchCase}
        wholeWord={wholeWord}
        onWholeWordChange={terminal ? setWholeWord : undefined}
        regex={regex}
        onRegexChange={terminal ? setRegex : undefined}
        labels={{
          placeholder: "Find",
          previous: "Previous",
          next: "Next",
          close: "Close",
          matchCase: "Match case",
          wholeWord: "Match whole word",
          regex: "Use regular expression",
        }}
        icon={(role) => <Icon name={icons[role]} />}
        replace={
          replace
            ? {
                open: replaceOpen,
                value: replacement,
                onChange: setReplacement,
                onReplace: () => setIndex((value) => (value % 3) + 1),
                onReplaceAll: () => setQuery(""),
                onToggle: () => setReplaceOpen((value) => !value),
                labels: { field: "Replace", replace: "Replace", replaceAll: "All", toggle: "Toggle Replace" },
              }
            : undefined
        }
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.find-pill",
  title: "Find and Replace",
  area: "UI primitives",
  height: 140,
  widths: { narrow: 500, normal: 640, wide: 800 },
  covers: ["ui/FindPill.tsx#FindPill"],
  load: async () => FindFixture,
  variants: {
    matches: { props: {}, note: "Hold a navigation button to see press feedback; Tab shows keyboard focus." },
    selected: { props: { selected: true }, note: "Match case keeps its selected hue while held." },
    replace: { props: { replace: true }, note: "Replace and All use the same immediate pressed feedback." },
    "terminal-idle": { props: { terminal: "idle" }, note: "Terminal find before a query: toggles shown, no count." },
    "terminal-streaming": {
      props: { terminal: "streaming" },
      note: "Pages stream in from the daemon: the count grows and keeps a + until the search completes.",
    },
    "terminal-invalid-pattern": {
      props: { terminal: "invalid" },
      note: "A bad regex shows Invalid pattern in the danger ink instead of a count.",
    },
    "terminal-toggles": { props: { terminal: "toggles", selected: true }, note: "Case, whole word and regex all on." },
    "glass-page": { props: { glass: "page" }, note: "Shipped (the default): the page's own glass." },
    "glass-host": {
      props: { glass: "host" },
      note: "experiments.findGlass (off by default): the App's transient glass under the pill (data-host-glass, role toast).",
    },
    "glass-host-busy": {
      props: { glass: "host", busy: true },
      note: "experiments.findGlass over busy transcript text: the glass keeps the pill legible.",
    },
    empty: {
      props: { noMatches: true, replace: true },
      note: "No matches uses the theme danger ink; disabled actions stay still.",
    },
  },
});
