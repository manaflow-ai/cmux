// l10n-allow-file: deterministic gallery fixtures, not shipped UI.
// Read provenance belongs to the final reply and opens only on request.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { MessageSource } from "../messageSources";

const FILE: MessageSource = {
  kind: "file",
  uri: "file:///workspace/src/queue.rs",
  title: "src/queue.rs",
  toolCallId: "read-queue",
};
const WEB: MessageSource = {
  kind: "web",
  uri: "https://docs.example.org/queues/leases",
  title: "Queue leases and retries",
  toolCallId: "fetch-leases",
};
const WIKI: MessageSource = {
  kind: "wiki",
  uri: "https://wiki.example.org/decisions/queue-ownership",
  title: "Queue ownership",
  toolCallId: "fetch-wiki",
  revision: "revision 7 · 2026-11-20",
  backlink: "https://wiki.example.org/decisions/queue-ownership/backlinks",
};
const RFD: MessageSource = {
  kind: "rfd",
  uri: "file:///workspace/docs/rfds/0042-queue-leases.md",
  title: "RFD 0042: Queue leases",
  toolCallId: "read-rfd",
};

const turn = (sources?: MessageSource[]) =>
  chat([
    user("How does a worker keep ownership of a queued job?", 2, { turnId: "sources-turn" }),
    assistant(
      "A worker claims the job with a lease and renews it while work continues. An expired lease makes the job available again.",
      1,
      {
        id: "assistant-sources-turn.gallery.1",
        turnId: "sources-turn",
        sources,
      },
    ),
    summary(1, { turnId: "sources-turn", status: "completed", toolCount: sources?.length ?? 0 }),
  ]);

const open: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-message-sources button"));
  ctx.document.querySelector<HTMLButtonElement>(".cv-message-sources button")?.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-message-sources .cv-web-sources__list"));
};

export default agentPaneEntry({
  id: "agent-pane.message-sources",
  title: "Reply sources",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/MessageSources.tsx"],
  widths: { narrow: 400, normal: 760, wide: 1040 },
  variants: {
    collapsed: {
      note: "A quiet Sources button below the final reply discloses four completed reads.",
      snapshot: turn([FILE, WEB, WIKI, RFD]),
    },
    expanded: {
      note: "Files, fetched pages, RFDs and wiki pages share one list, described as reads during the turn.",
      snapshot: turn([FILE, WEB, WIKI, RFD]),
      play: open,
    },
    "wiki-revision": {
      note: "An explicit wiki revision and backlink remain next to the page they identify.",
      snapshot: turn([WIKI]),
      play: open,
    },
    "file-spaces-unicode": {
      note: "The file opener receives the decoded path, including spaces, Unicode and a literal hash.",
      snapshot: turn([
        { ...FILE, uri: "file:///workspace/docs/Design%20notes%20%23%C3%A9.md", title: "Design notes #é.md" },
      ]),
      play: open,
    },
    "without-provenance": {
      note: "A reply without recorded successful reads has no Sources button.",
      snapshot: turn(),
    },
  },
});
