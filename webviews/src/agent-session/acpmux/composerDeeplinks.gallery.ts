// l10n-allow-file: gallery fixtures (sample drafts and links), not shipped UI.
// cmux deeplinks in the composer's draft (Leo, 2026-11-03: "hm i wonder if those should be rendered
// the deeplinks within the composer too..."): a workspace link (`cmux-nightly://workspace/ws_…`), an
// agent link (`cmux://agent/…`) and a web agent link (`https://cmux.com/deeplink/agent?…`). The
// draft keeps each URL as its text; compare the arms (`composer-deeplink-look`: link, chip, plain)
// for how it reads. The sent prompt above draws the same links, so draft and sent match.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { composerDeeplinkLook } from "./composer/deeplinkLook.experiment";

const WORKSPACE = "cmux-nightly://workspace/ws_cca525bafd4d2b969dad8fdb549b0c61";
const AGENT = "cmux://agent/claude/9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
const WEB_AGENT = "https://cmux.com/deeplink/agent?harness=claude&session=9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";

const DRAFT = `Open ${WORKSPACE} and compare it with the chat at ${AGENT}.`;
const SENT = `The retry fix is in ${WORKSPACE}, the review chat is ${WEB_AGENT}`;

const snapshot = chat([
  user(SENT, 8),
  assistant("I'll read both before changing anything.", 7),
  summary(7, { status: "completed" }),
]);

/** Waits for the draft to show `url`, its deeplink (none in the plain arm, so it waits for the text).
 * Each variant waits for a URL its own draft has: the web agent link's draft has no workspace link. */
const drawnWith = (url: string) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md")?.textContent?.includes(url));
};
const drawn = drawnWith(WORKSPACE);

const variant = (note: string, draft: string, url = WORKSPACE): AgentPaneVariant => ({
  note,
  ready: { draft },
  snapshot,
  play: drawnWith(url),
});

export default agentPaneEntry({
  id: "agent-pane.composer-deeplinks",
  title: "Composer deeplinks",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/composer/deeplinkTokens.ts", "agent-session/acpmux/composer/deeplinks.ts"],
  keywords: ["deeplink", "link", "workspace link", "agent link", "cmux://"],
  variants: {
    "workspace-and-agent": variant(
      "A draft with a workspace link and an agent link: each draws as a link, its text the URL; the sent prompt above draws its links the same way.",
      DRAFT,
    ),
    "web-agent-link": variant(
      "A cmux.com agent deeplink in the draft draws as a link too.",
      `Pick up where ${WEB_AGENT} left off`,
      WEB_AGENT,
    ),
    "not-a-deeplink": variant(
      "Other schemes and plain words stay text: cmux:/x, javascript:, a path.",
      `Look at cmux:/workspace and src/cmux/workspace.ts, then ${WORKSPACE}.`,
    ),
  },
  experiment: {
    definition: composerDeeplinkLook,
    script: [{ name: "Draw the draft", run: drawn }],
  },
});
