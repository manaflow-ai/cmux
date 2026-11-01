// l10n-allow-file: gallery sample conversation, not shipped UI copy.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { BTW_INLINE } from "../btwCapability";
import { WORKED_SESSION } from "../mockFixture";

const snapshot = chat(
  [
    user("Check the retry helper and fix the failing test", 1),
    assistant("I’m checking the retry helper and its timer tests.", 0.5, { streaming: true }),
  ],
  { isWorking: true },
);
const answer = "The **backoff timer** raced the mocked clock: the first retry waited 0 ms.";
// The app answers `chat.btw.inline` with the reply text as `{ text }`.
const native = { "chat.btw.inline": { text: answer } };
// `/btw` asks through the chat's acpmux client, which the preview transport does not run: the
// asking variants run the mock daemon, naming the inline capability as a current acpmux does, and
// show the chat the client attached to (its session, in a folder the mock trusts).
const attached = {
  ...snapshot,
  sessionId: WORKED_SESSION,
  summary: { ...snapshot.summary!, sessionId: WORKED_SESSION, cwd: "~/code/cmux" },
};
const asking = { ready: { transport: "mock" }, mockCapabilities: [BTW_INLINE], snapshot: attached };
async function ask(ctx: PlayContext) {
  // The question goes through the attached client, once it has the folder's trust answer.
  await ctx.waitFor(() =>
    (ctx.document.defaultView as Window & { cmuxGalleryLog?: { method: string }[] })?.cmuxGalleryLog?.some(
      (call) => call.method === "acpmux acp.trust.get",
    ),
  );
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
    answered: { ...asking, native, play: answered },
    pending: { ...asking, native, nativeDelayMs: { "chat.btw.inline": 120_000 }, play: ask },
    failed: {
      ...asking,
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
      ...asking,
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
