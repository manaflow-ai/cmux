// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Placement (c): the real New Tab page (NewTabScreen, the shipped first-run state: an agent signed in,
// no chats yet) with the history chip in its notice slot under the composer.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { NewTabScreen } from "../../agent-session/acpmux/newtab/NewTabScreen";
import { ImportHistoryChip } from "./ImportHistoryChip";
import { HISTORY_COUNTS } from "./fixtures";

type Props = { state: "ready" | "running" };

async function load() {
  const { NewTabScreen } = await import("../../agent-session/acpmux/newtab/NewTabScreen");
  const base: ComponentProps<typeof NewTabScreen> = {
    snapshot: noChat([]),
    home: "/Users/you",
    cwd: "/Users/you",
    projects: [{ cwd: "/Users/you", label: "you" }],
    knownProjects: null,
    onAsk: () => {},
    onOpen: () => {},
    onSearch: () => {},
    onShell: () => {},
    onJump: () => {},
    onOpenSession: () => {},
    onShowAll: () => {},
    onBrowseProject: async () => undefined,
    template: "minimal",
  };
  return function NewTabWithHistoryChip({ state }: Props) {
    const [shown, setShown] = useState<Props["state"] | "dismissed">(state);
    const chip =
      shown === "dismissed" ? null : (
        <ImportHistoryChip
          state={shown}
          title="Bring in your Claude and Codex history"
          counts={`${HISTORY_COUNTS.claudeSessions} sessions · ${HISTORY_COUNTS.codexThreads} threads`}
          running="Bringing in your history… you can keep working"
          dismiss="Not now"
          onStart={() => setShown("running")}
          onDismiss={() => setShown("dismissed")}
        />
      );
    return <NewTabScreen {...base} notice={chip} />;
  };
}

export default componentEntry<Props>({
  id: "prototype.import-history-new-tab",
  title: "Bring your history: New Tab chip",
  area: "Prototypes",
  experimental: true,
  pane: true,
  covers: ["prototypes/import-history/ImportHistoryChip.tsx"],
  keywords: ["import", "history", "memory", "claude code", "codex", "new tab", "chip"],
  height: 420,
  widths: { narrow: 420, normal: 760, wide: 1040 },
  load,
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/newtab/screen.css"),
    ]),
  variants: {
    chip: {
      note: "(c) One chip under the composer on a Mac with history not yet in cmux: tools, counts, ×.",
      props: { state: "ready" },
    },
    running: {
      note: "After a click: the chip says the import runs; the composer stays usable.",
      props: { state: "running" },
    },
  },
});
