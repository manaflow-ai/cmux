// l10n-allow-file: gallery fixtures.
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { componentEntry } from "../../gallery/entry";
import { TerminalHistoryPage } from "./TerminalHistoryPage";
import { TerminalHistoryStore } from "./store";
import type { TranscriptTurn } from "./types";

const turns: TranscriptTurn[] = [
  {
    prompt: "Can I read the whole session after a restart?",
    answer: "Yes. Earlier turns are loaded from the transcript as you scroll.",
    tools: [],
  },
  {
    prompt: "Find the part where we discussed paging.",
    answer: "The transcript search finds it without loading the whole file.",
    tools: [{ title: "Read transcript page" }, { title: "Search transcript" }],
  },
  {
    prompt: "Open the older page.",
    answer: "The tool calls stay folded until you open them.",
    tools: [{ title: "Load page before byte offset" }],
  },
];

function GalleryTerminalHistory(props: { title?: string; turns?: TranscriptTurn[]; query?: string }) {
  return (
    <TerminalHistoryPage
      strings={createStrings(table)}
      store={new TerminalHistoryStore(null, "gallery")}
      fixture={{ title: props.title, turns: props.turns ?? turns, query: props.query }}
    />
  );
}

export default componentEntry({
  id: "terminal-history.viewer",
  title: "Terminal transcript viewer",
  area: "Agent chat",
  experimental: true,
  height: 680,
  widths: { narrow: 600, normal: 920, wide: 1300 },
  covers: ["pages/terminal-history/TerminalHistoryPage.tsx#TerminalHistoryPage"],
  load: async () => GalleryTerminalHistory,
  styles: () => import("./styles.css"),
  variants: {
    latest: { note: "Latest transcript page, with tool calls folded.", props: {} },
    searching: {
      note: "Cmd-F search focused with one matching turn highlighted.",
      props: { query: "paging" },
    },
    compact: {
      note: "A narrow terminal pane affordance that opens the same read-only viewer.",
      props: { title: "Claude Code · earlier history", turns: turns.slice(0, 2) },
    },
  },
});
