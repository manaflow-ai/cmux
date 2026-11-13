// l10n-allow-file: gallery fixtures, not shipped UI.
// The Agent Board page (cmux-page://cmux.agent-board/): the same page main.tsx mounts, over the mock
// `cmux.agentBoard.*` host instead of the app's bridge.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { AgentBoardPage } from "./AgentBoardPage";
import type { MockBoardKind } from "./fixtures";
import { MockAgentBoardProvider } from "./mockProvider";
import { AgentBoardStore } from "./store";

type Props = { kind?: MockBoardKind; loading?: boolean; failed?: boolean };

/** A host whose first read never answers: the loading state. */
const pending: PageClient = {
  call: () => new Promise(() => {}),
  subscribe: async () => () => {},
  handle: () => () => {},
};

function AgentBoardGallery({ kind = "live", loading = false, failed = false }: Props) {
  const [store] = useState(() => {
    const client = loading
      ? pending
      : new MockAgentBoardProvider(
          kind,
          undefined,
          failed ? { code: "cmux.op.failed", message: "unreadable" } : undefined,
        );
    const store = new AgentBoardStore(client);
    void store.start();
    return store;
  });
  const [strings] = useState(() => createStrings(table));
  return <AgentBoardPage store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.agent-board",
  title: "Agent Board",
  area: "Pages",
  keywords: [
    "agent",
    "board",
    "ledger",
    "evidence",
    "decisions",
    "permutations",
    "work-tracking",
    "onboarding",
    "matrix",
  ],
  covers: ["page:cmux.agent-board", "pages/agent-board/AgentBoardPage.tsx"],
  load: async () => AgentBoardGallery,
  styles: () =>
    Promise.all([
      import("../shared/pageBase.css"),
      import("../../ui/ui.css"),
      import("../../ui/controls.css"),
      import("./styles.css"),
    ]),
  height: 980,
  widths: { narrow: 390, normal: 1180, wide: 1500 },
  variants: {
    off: {
      note: "Off by default: what it does, the token cost, and one button to turn it on.",
      props: { kind: "off" },
    },
    "on-empty": { note: "Turned on, no ledger yet: where ledgers are read from.", props: { kind: "empty" } },
    loading: { note: "The first read.", props: { loading: true } },
    live: {
      note: "Four agents' ledgers, Matrix: each capability's states with the proof in each cell.",
      props: { kind: "live" },
    },
    error: {
      note: "Unreadable ledger lines show as rows; the rest of the board still works.",
      props: { kind: "error" },
    },
    stress: { note: "18 agents, long titles, a truncated ledger.", props: { kind: "stress" } },
    failed: { note: "The host could not read the ledgers.", props: { failed: true } },
  },
});
