// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../format";
import type { HistoryLinkProps } from "./HistoryLinkPreview";

export default componentEntry<HistoryLinkProps>({
  id: "terminal.earlier-history",
  title: "Earlier terminal agent history",
  area: "Terminal",
  covers: ["gallery/terminal-history/HistoryLinkPreview.tsx"],
  height: 130,
  keywords: ["terminal", "transcript", "history"],
  load: () => import("./HistoryLinkPreview").then((module) => module.HistoryLinkPreview),
  variants: {
    dated: { note: "Corner action with the span of a known transcript.", props: { variant: "dated" } },
    compact: { note: "A narrow split keeps the clock and its full accessible name.", props: { variant: "compact" } },
    undated: { note: "The action before transcript dates arrive.", props: { variant: "undated" } },
    separator: { note: "Alternative placement at the resume boundary.", props: { variant: "separator" } },
  },
});
