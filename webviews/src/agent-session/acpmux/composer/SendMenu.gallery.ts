// l10n-allow-file: gallery fixtures (sample drafts and chats), not shipped UI.
// Send's menu (composer/SendMenu.tsx): a right-click or a long press on the composer's Send lists
// the ways the typed draft can go, each with the key that sends it that way from the prompt. The
// whole pane draws it, so the rows come from the chat's own state: Queue for later only while a
// turn runs that Send would steer, Send in side chat only where `/side` can fork the chat. Compare
// the row looks with experiment `send-menu-look` (shortcut text, key caps, icons).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { sendMenuLook } from "./sendMenuLook.experiment";

const SEND = { selector: ".acpmux-composer .acpmux-send" };
const DRAFT = "Also cover the timeout path in the retry test";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  // A finished turn acpmux can fork through (its seq): `/side` forks an idle chat from here.
  summary(9, { status: "completed", seq: 3 }),
];
const working = [
  ...finished,
  user("Now add a test for it", 1),
  assistant("Writing the test…", 0.5, { streaming: true }),
];

/** A turn runs, for an agent that takes Return into it (Send steers, ⌘Return queues). */
function running(): AcpmuxSnapshot {
  const snapshot = chat(working, { isWorking: true });
  return { ...snapshot, summary: { ...snapshot.summary!, steering: true } };
}

const menuOpen = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));

async function rightClickSend(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(SEND.selector));
  await ctx.contextMenu(SEND);
  await menuOpen(ctx);
}

const variant = (note: string, snapshot: AcpmuxSnapshot, play = rightClickSend): AgentPaneVariant => ({
  note,
  ready: { draft: DRAFT },
  snapshot,
  play,
});

export default agentPaneEntry({
  id: "agent-pane.composer-send-menu",
  title: "Composer send menu",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  keywords: ["send", "queue", "fork", "side chat", "right-click", "long press", "shortcut"],
  covers: ["agent-session/acpmux/composer/SendMenu.tsx#SendMenu"],
  variants: {
    "turn-running": variant(
      "Right-click on Send mid-turn: Send ↩ (steers), Queue for later ⌘↩, Send in side chat ⌥↩.",
      running(),
    ),
    idle: variant(
      "Right-click on Send after a turn: Send ↩ and Send in side chat ⌥↩. Queue for later would only send, so it has no row.",
      chat(finished),
    ),
    "no-fork": variant(
      "A chat that cannot fork (the agent serves no fork): no Send in side chat row, never a disabled one.",
      { ...running(), canFork: false },
    ),
    "long-press": variant(
      "A press held on Send for half a second opens the same menu; letting go sends nothing.",
      running(),
      async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(SEND.selector));
        await ctx.pointer.down(SEND);
        await menuOpen(ctx);
      },
    ),
  },
  experiment: {
    definition: sendMenuLook,
    script: [{ name: "Right-click Send", run: rightClickSend }],
  },
});
