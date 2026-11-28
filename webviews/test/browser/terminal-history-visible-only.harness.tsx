// l10n-allow-file: bench fixture transcript, not shipped UI.
// The real terminal transcript viewer over N turns (`#n=2000`), for
// bench/terminal-history-offscreen.bench.ts. `#arm=off` turns the offscreen-turn rule off
// (`content-visibility: visible` on every turn), so both arms run the same page and build; the
// default arm is the page as it ships. `benchMountMs` is the time from render() to the first
// painted frame.
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/terminal-history/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/terminal-history/generated/strings.json";
import { TerminalHistoryPage } from "../../src/pages/terminal-history/TerminalHistoryPage";
import { TerminalHistoryStore } from "../../src/pages/terminal-history/store";
import type { TranscriptTurn } from "../../src/pages/terminal-history/types";
import { UiProvider } from "../../src/ui/UiProvider";

declare global {
  interface Window {
    benchReady: boolean;
    benchMountMs: number;
  }
}

const params = new URLSearchParams(location.hash.slice(1));
const n = Number(params.get("n") ?? 2000);
if (params.get("arm") === "off") {
  const style = document.createElement("style");
  style.textContent = ".terminal-history-turn { content-visibility: visible !important; }";
  document.head.append(style);
}
const sentence = "The reader pages older turns in from the log as the person scrolls up toward the start";
const turns: TranscriptTurn[] = Array.from({ length: n }, (_, index) => ({
  prompt: `Turn ${index}: ${sentence.slice(0, 40 + (index % 5) * 9)}?`,
  answer: Array.from({ length: 2 + (index % 4) }, (_, p) => `${sentence} (${index}.${p}).`).join(" "),
  tools: Array.from({ length: index % 3 }, (_, t) => ({ title: `Read file ${index}-${t}` })),
}));
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
const started = performance.now();
createRoot(root).render(
  <UiProvider container={root}>
    <TerminalHistoryPage
      store={new TerminalHistoryStore(null, "gallery")}
      strings={strings}
      fixture={{ title: "Bench", turns }}
    />
  </UiProvider>,
);
requestAnimationFrame(() =>
  setTimeout(() => {
    window.benchMountMs = performance.now() - started;
    window.benchReady = true;
  }, 0),
);
