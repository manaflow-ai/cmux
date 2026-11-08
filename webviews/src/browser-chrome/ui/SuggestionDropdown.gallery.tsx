// l10n-allow-file: gallery fixtures (sample suggestions), not shipped UI.
// The suggestion card under the real toolbar, sized and placed at the omnibar as the host places it.
// The pointer moves the highlight here as the omnibox state machine would.
import { useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import { BrowserToolbar } from "./BrowserToolbar";
import { toolbarProps, typedSuggestions } from "./fixtures";
import { SuggestionDropdown, type SuggestionLook, type SuggestionRow } from "./SuggestionDropdown";
import { toolbarStrings } from "./strings";
import { resolveChip, type ChipLabel } from "./toolbarModel";

type Props = {
  suggestions: SuggestionRow[];
  highlighted: number | null;
  text: string;
  look?: SuggestionLook;
  upward?: boolean;
  chipIcon?: string;
  chipLabel?: ChipLabel;
};

function DropdownFixture({
  suggestions,
  highlighted,
  text,
  look = "joined",
  upward = false,
  chipIcon,
  chipLabel,
}: Props) {
  const [active, setActive] = useState(highlighted);
  const frame = useRef<HTMLDivElement>(null);
  const [place, setPlace] = useState<CSSProperties>({ visibility: "hidden" });
  useLayoutEffect(() => {
    const root = frame.current;
    const bar = root?.querySelector<HTMLElement>(".bc-omnibar");
    if (!root || !bar) return;
    const measure = () => {
      const outer = root.getBoundingClientRect();
      const box = bar.getBoundingClientRect();
      setPlace({
        position: "absolute",
        insetInlineStart: box.left - outer.left,
        width: box.width,
        ...(upward ? { bottom: outer.bottom - box.top } : { top: box.bottom - outer.top }),
      });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(bar);
    return () => observer.disconnect();
  }, [upward]);
  const chip = resolveChip(null, true, chipIcon ?? "browser.omnibox.search");
  const props = toolbarProps({
    omnibar: {
      text,
      chip: chipLabel ? { ...chip, label: chipLabel } : chip,
      bookmark: "hidden",
      editing: true,
      suggestionsOpen: look !== "floating",
      upward,
    },
  });
  return (
    <div
      ref={frame}
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        justifyContent: upward ? "flex-end" : "flex-start",
        height: "100%",
        paddingBlock: 8,
      }}
    >
      <BrowserToolbar {...props} onCommand={() => {}} />
      <div style={place}>
        <SuggestionDropdown
          suggestions={suggestions}
          highlighted={active}
          look={look}
          upward={upward}
          label={toolbarStrings().t("browser.omnibar.placeholder")}
          onCommand={(command) => command.type === "hover" && command.index !== null && setActive(command.index)}
        />
      </div>
    </div>
  );
}

const typed = { suggestions: typedSuggestions, highlighted: 0, text: "docs example" };

export default componentEntry<Props>({
  id: "browser-chrome.suggestions",
  title: "Omnibar suggestions",
  area: "Browser chrome",
  experimental: true,
  height: 340,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["browser-chrome/ui/SuggestionDropdown.tsx"],
  keywords: ["omnibox", "dropdown", "autocomplete", "address bar"],
  load: async () => DropdownFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "joined", label: "Joined" },
        { value: "floating", label: "Floating" },
        { value: "two-line", label: "Two lines" },
      ],
      defaultValue: "joined",
    },
  ],
  variants: {
    typing: { props: typed, note: "Recommended look: the bar and card are one shape." },
    "typing-floating": {
      props: { ...typed, look: "floating" },
      note: "A separate glass popup under the bar.",
    },
    "typing-two-line": { props: { ...typed, look: "two-line" }, note: "Title over URL." },
    "highlight-history": {
      props: { ...typed, highlighted: 2 },
      note: "A page row with its site icon highlighted.",
    },
    "no-highlight": { props: { ...typed, highlighted: null } },
    upward: {
      props: { ...typed, upward: true },
      note: "Toolbar at the bottom of the pane: the card opens upward.",
    },
    "keyword-session": {
      props: {
        text: "standup",
        highlighted: 0,
        chipIcon: "browser.toolbar.extensions",
        chipLabel: { keyword: "Quick Notes" },
        suggestions: [
          { kind: "keyword", title: "standup notes", detail: "Quick Notes" },
          { kind: "keyword", title: "standup template", detail: "Quick Notes" },
        ],
      },
    },
    answer: {
      props: {
        text: "12*7",
        highlighted: 0,
        suggestions: [
          { kind: "answer", title: "= 84", detail: "" },
          { kind: "search", title: "12*7", detail: "Google Search" },
        ],
      },
    },
  },
});
