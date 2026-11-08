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

const TAB_ID = "tab_0123456789abcdef0123456789abcdef";
const TAB = `cmux-nightly://tab/${TAB_ID}`;

/** The host names the draft's workspace and tab after the draft drew (`linkPlaces`, as the app
 * pushes it): each draws as the sent message's chip, the kind's icon and the title on its wash with
 * its padding and radius, and the draft's line keeps its height (review of #38166: the wash had been
 * 0 px tall, only its side padding showing). */
const namedLater = async (ctx: PlayContext) => {
  const doc = ctx.document;
  await drawnWith(TAB)(ctx);
  const line = () => doc.querySelector<HTMLElement>(".acpmux-md p");
  const view = doc.defaultView as unknown as {
    cmuxAcpmuxBridge?: { applyLinkPlaces?(places: unknown): void };
  };
  view.cmuxAcpmuxBridge?.applyLinkPlaces?.([
    { id: WORKSPACE.slice(WORKSPACE.lastIndexOf("/") + 1), kind: "workspace", title: "Retry fix" },
    { id: TAB_ID, kind: "tab", title: "zsh", workspace: "cmux next" },
  ]);
  await ctx.waitFor(() => doc.querySelectorAll(".is-titled[data-title][data-icon]").length === 2);
  const chips = [...doc.querySelectorAll<HTMLElement>(".is-titled[data-title][data-icon]")];
  for (const chip of chips) {
    const icon = getComputedStyle(chip, "::before");
    const title = getComputedStyle(chip, "::after");
    if (!(icon.maskImage || icon.getPropertyValue("-webkit-mask-image")).includes("data:image/svg"))
      throw new Error(`the ${chip.dataset.kind} chip draws no kind icon`);
    if (
      title.backgroundColor === "rgba(0, 0, 0, 0)" ||
      title.paddingTop !== "1px" ||
      title.borderTopLeftRadius !== "4px"
    )
      throw new Error(`the ${chip.dataset.kind} chip's title has no wash, padding or radius`);
  }
  // One line of text and two chips: the line is the field's one line height, as with no chip.
  const p = line()!;
  const lineHeight = parseFloat(getComputedStyle(p).lineHeight);
  if (Number.isFinite(lineHeight) && Math.abs(p.getBoundingClientRect().height - lineHeight) > 0.5)
    throw new Error(`the draft's line is ${p.getBoundingClientRect().height}px, not its ${lineHeight}px line`);
};

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
  covers: [
    "agent-session/acpmux/composer/deeplinkTokens.ts",
    "agent-session/acpmux/composer/deeplinks.ts",
    "agent-session/acpmux/composer/deeplinkTitles.ts",
    "agent-session/acpmux/icons/iconMask.ts",
  ],
  keywords: ["deeplink", "link", "workspace link", "agent link", "cmux://"],
  variants: {
    "workspace-and-agent": variant(
      "A draft with a workspace link and an agent link: each draws as a link, its text the URL; the sent prompt above draws its links the same way.",
      DRAFT,
    ),
    "named-by-the-app": {
      note: "The app names the draft's workspace and tab (its `linkPlaces` push, after the draft drew): each draws as the sent message's chip, the kind's icon and the title on the session chip's wash, its padding and radius; the line keeps its height and the draft's text is still the link.",
      ready: { draft: `Open ${WORKSPACE} and ${TAB}` },
      snapshot,
      play: namedLater,
    },
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
