// l10n-allow-file: gallery sample conversation, not shipped UI copy.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const snapshot = chat(
  [
    user("Check the retry helper and fix the failing test", 1),
    assistant("I’m checking the retry helper and its timer tests.", 0.5, { streaming: true }),
  ],
  { isWorking: true },
);
const answer = "The **backoff timer** raced the mocked clock: the first retry waited 0 ms.";
const native = { "chat.btw.inline": answer };
async function ask(ctx: PlayContext) {
  await ctx.type("/btw Why does the retry test flake?", { selector: ".acpmux-composer-prompt .ProseMirror" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-btw-note"));
}
async function answered(ctx: PlayContext) {
  await ask(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-btw-note")?.textContent?.includes("backoff timer"));
}
export default agentPaneEntry({
  id: "agent-pane.btw-aside",
  title: "/btw aside",
  area: "Agent pane",
  height: 480,
  widths: { narrow: 340, normal: 640, wide: 900 },
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason: "The composer action row can gain its Send control when /btw is submitted.",
    },
    longFrameFailMs: {
      value: 100,
      reason:
        "The agent pane fixture includes a real composer submit and Chromium headless can report input-frame scheduling above 33 ms.",
    },
  },
  covers: ["agent-session/acpmux/aside/BtwAside.tsx#BtwAside"],
  variants: {
    before: { snapshot },
    answered: { snapshot, native, play: answered },
    pending: { snapshot, native, nativeDelayMs: { "chat.btw.inline": 120_000 }, play: ask },
    failed: {
      snapshot,
      native: {
        "chat.btw.inline": {
          nativeError: { code: "native.failed", userMessage: "The connection closed before the answer arrived." },
        },
      },
      play: async (ctx) => {
        await ask(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-btw-note [role=alert]"));
      },
    },
    dismiss: {
      snapshot,
      native,
      checks: {
        layoutShiftMax: { value: 0.2, reason: "Dismissing removes the aside and closes its space in the transcript." },
      },
      play: async (ctx) => {
        await answered(ctx);
        await ctx.click({ role: "button", name: "Dismiss" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-btw-note") === null);
      },
    },
  },
});
