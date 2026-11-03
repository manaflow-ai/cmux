// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import { Icon, type IconName } from "../icons";
import { FindPill, type FindPillIconRole } from "./FindPill";

type Props = { noMatches?: boolean; selected?: boolean; replace?: boolean };
const icons = {
  search: "search",
  previous: "chevronUp",
  next: "chevronDown",
  close: "close",
} as const satisfies Record<FindPillIconRole, IconName>;

function FindFixture({ noMatches = false, selected = false, replace = false }: Props) {
  const [query, setQuery] = useState("needle");
  const [matchCase, setMatchCase] = useState(selected);
  const [replacement, setReplacement] = useState("replacement");
  const [replaceOpen, setReplaceOpen] = useState(replace);
  const [index, setIndex] = useState(1);
  return (
    <div style={{ padding: 24 }}>
      <FindPill
        query={query}
        onQueryChange={setQuery}
        status={noMatches ? "No matches" : `${index} of 3`}
        noMatches={noMatches}
        canStep={!noMatches}
        onNext={() => setIndex((value) => (value % 3) + 1)}
        onPrevious={() => setIndex((value) => ((value + 1) % 3) + 1)}
        onClose={() => setQuery("")}
        matchCase={matchCase}
        onMatchCaseChange={setMatchCase}
        labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close", matchCase: "Match case" }}
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
    empty: {
      props: { noMatches: true, replace: true },
      note: "No matches uses the theme danger ink; disabled actions stay still.",
    },
  },
});
