// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { PlayContext } from "../gallery/play";
import type { TerminalTailPinDesignsProps } from "./TerminalTailPinDesigns";

/** Advances every pinned tail twice and fails if any row's height or top changes. */
async function updatesInPlace(ctx: PlayContext) {
  const rows = () => [...ctx.document.querySelectorAll(".ttp-row")].map((row) => row.getBoundingClientRect());
  const tail = () => ctx.document.querySelector(".ttp-row[data-has-tail] .ttp-tail-text")?.textContent ?? "";
  const before = rows();
  for (let step = 0; step < 2; step++) {
    const previous = tail();
    await ctx.click({ role: "button", name: "Next output line" });
    await ctx.waitFor(() => tail() !== previous);
    const after = rows();
    after.forEach((rect, index) => {
      if (rect.height !== before[index]!.height || rect.top !== before[index]!.top)
        throw new Error(`row ${index} moved when its tail changed`);
    });
  }
}

export default componentEntry<TerminalTailPinDesignsProps>({
  id: "sidebar.terminal-tail-pins",
  title: "Terminal tail pins: the status entry a pinned terminal writes",
  area: "Sidebar",
  experimental: true,
  covers: ["sidebar/TerminalTailPinDesigns.tsx"],
  height: 260,
  keywords: ["pin", "terminal", "tail", "status entry", "last line"],
  anchors: [{ selector: ".ttp-sidebar" }],
  load: () => import("./TerminalTailPinDesigns").then((module) => module.TerminalTailPinDesigns),
  variants: {
    "icon-line": {
      note: "Recommended. Daemon writes icon: terminal glyph (SF Symbol `terminal`), color: none (secondary ink), text: the tail line.",
      props: { design: "icon-line" },
    },
    "title-prefix": {
      note: "Daemon writes icon: none, color: none (secondary ink), text: `<terminal tab title> · <tail>`.",
      props: { design: "title-prefix" },
    },
    tinted: {
      note: "Daemon writes icon: terminal glyph, color: the theme accent, text: the tail line.",
      props: { design: "tinted" },
    },
    plain: {
      note: "Daemon writes icon: none, color: tertiary ink, text: the tail line.",
      props: { design: "plain" },
    },
    "update-instant": {
      note: "icon-line as new output arrives: the text swaps in place with no animation; row heights and tops stay put.",
      props: { design: "icon-line", live: true, swap: "instant" },
      play: updatesInPlace,
    },
    "update-crossfade": {
      note: "icon-line with a 120 ms fade-in of the new line in the same box (none under reduced motion); no row moves.",
      props: { design: "icon-line", live: true, swap: "crossfade" },
      play: updatesInPlace,
    },
  },
});
