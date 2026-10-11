import { useMemo, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import type { DiffViewerLabelResolver } from "../labels";
import type { FindMatch } from "./model";
import { FindBar } from "./FindBar";
import type { DiffFindController } from "./useDiffFind";

type Props = {
  initialQuery: string;
  initialMatches: number;
  requestToken: number;
};

const labels: Record<string, string> = {
  findInDiff: "Find in diff",
  findPreviousMatch: "Previous match",
  findNextMatch: "Next match",
  findClose: "Close find",
};
const label = ((key: string) => labels[key] ?? key) as DiffViewerLabelResolver;

function fixtureMatches(count: number): FindMatch[] {
  return Array.from({ length: count }, (_, index) => ({
    itemId: `fixture-file-${index + 1}`,
    side: "additions" as const,
    lineNumber: index + 1,
    start: 0,
    length: 6,
    occurrence: 0,
    lineText: "needle in a fixture line",
  }));
}

function GalleryFindBar({ initialQuery, initialMatches, requestToken: initialRequestToken }: Props) {
  const [query, setQuery] = useState(initialQuery);
  const [activeIndex, setActiveIndex] = useState(0);
  const [open, setOpen] = useState(true);
  const [requestToken, setRequestToken] = useState(initialRequestToken);
  const matches = useMemo(() => fixtureMatches(initialMatches), [initialMatches]);
  const controller = useMemo<DiffFindController>(
    () => ({
      matches: query === "" ? [] : matches,
      activeIndex: query === "" || matches.length === 0 ? 0 : Math.min(activeIndex, matches.length - 1),
      activeMatch: query === "" ? null : (matches[activeIndex] ?? null),
      setQuery: (nextQuery) => {
        setQuery(nextQuery);
        setActiveIndex(0);
      },
      goToNext: () => setActiveIndex((index) => (matches.length === 0 ? 0 : (index + 1) % matches.length)),
      goToPrevious: () =>
        setActiveIndex((index) => (matches.length === 0 ? 0 : (index - 1 + matches.length) % matches.length)),
      closeFind: () => setOpen(false),
      findBarRef: () => undefined,
    }),
    [activeIndex, matches, query],
  );

  if (!open) {
    return <div data-find-closed>Find closed</div>;
  }
  return (
    <div id="viewer" data-find-fixture>
      <button type="button" onClick={() => setRequestToken((token) => token + 1)}>
        Refocus find
      </button>
      <FindBar controller={controller} label={label} query={query} requestToken={requestToken} />
    </div>
  );
}

const next: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Next match" });
  await ctx.waitFor(() => ctx.find({ selector: "#diff-find-count" }).textContent === "2/3");
};

const previous: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Previous match" });
  await ctx.waitFor(() => ctx.find({ selector: "#diff-find-count" }).textContent === "3/3");
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "textbox", name: "Find in diff" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ selector: "#diff-find-count" }).textContent === "2/3");
  await ctx.press("Shift+Enter");
  await ctx.waitFor(() => ctx.find({ selector: "#diff-find-count" }).textContent === "1/3");
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector("[data-find-closed]") !== null);
};

const refocus: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Refocus find" });
  await ctx.waitFor(() => ctx.document.activeElement?.id === "diff-find-input");
};

export default componentEntry<Props>({
  id: "diff.find-bar",
  title: "Diff find bar",
  area: "Diff viewer",
  height: 180,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "#diff-find-anchor" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Changing the active match must not move the sticky find bar anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Find navigation is an overlay action and must not reflow the viewer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Find navigation should settle within one responsive interaction frame on the gallery host.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Find navigation and dismissal should settle promptly for repeated code review use.",
    },
  },
  styles: () => import("../styles.css"),
  covers: ["find/FindBar.tsx#FindBar"],
  load: async () => GalleryFindBar,
  variants: {
    empty: { props: { initialQuery: "", initialMatches: 3, requestToken: 1 } },
    matches: { props: { initialQuery: "needle", initialMatches: 3, requestToken: 1 } },
    next: {
      props: { initialQuery: "needle", initialMatches: 3, requestToken: 1 },
      play: next,
    },
    previous: {
      props: { initialQuery: "needle", initialMatches: 3, requestToken: 1 },
      play: previous,
    },
    keyboard: {
      props: { initialQuery: "needle", initialMatches: 3, requestToken: 1 },
      play: keyboard,
    },
    refocus: {
      props: { initialQuery: "needle", initialMatches: 3, requestToken: 1 },
      play: refocus,
    },
    "no-matches": { props: { initialQuery: "missing", initialMatches: 0, requestToken: 1 } },
  },
});
