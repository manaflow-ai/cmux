// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// The composer while a new chat starts in Cloud. Leo, 2026-11-09: "And also, I can't click into the
// composer at all to, like potentially type other stuff while it's doing that initial load
// situation." The box used to go inert for the whole start (#28686); now it stays open: the sent
// prompt shows as the message with the start under it, what is typed meanwhile moves to the started
// chat's composer as a draft (the host seeds it there), and Send waits. The pane runs its real client on
// the in-page mock daemon; the host's `cloud.startChat` answers late (or refuses, for a failure).
// Compare arms shows the `cloud-start-composer-look` experiment.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import { cloudStartComposerLook } from "./cloudStartComposer.experiment";

const PROMPT = "Run the sidebar tests and fix what fails";
const TYPED = "Also check the nightly once that is done";
const FIELD = ".acpmux-composer-prompt [contenteditable='true']";

type Frame = Window & {
  cmuxAcpmuxDebug?: { runMode(mode?: string): { runMode?: string | null } };
  cmuxExperiments?: Record<string, string>;
};

/// A new chat in a trusted folder of the mock daemon, where the host offers Cloud.
const ready = { transport: "mock", newSession: true, sandboxState: true, cwd: "~/code/cmux" };
const native = { "sandbox.state": {}, "transport.gesture": { ticket: "gallery" } };

/// Cloud picked, the prompt sent: the start is out and the composer is empty and open.
async function sendInCloud(ctx: PlayContext, arm?: string) {
  const frame = ctx.document.defaultView as Frame;
  if (arm) frame.cmuxExperiments = { ...frame.cmuxExperiments, [cloudStartComposerLook.id]: arm };
  await ctx.waitFor(() => ctx.document.querySelector(FIELD), { capMs: 10_000 });
  await ctx.waitFor(() => frame.cmuxAcpmuxDebug?.runMode("cloud").runMode === "cloud", { capMs: 10_000 });
  await ctx.type(PROMPT, { selector: FIELD });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-start"), { capMs: 10_000 });
}

const starting =
  (arm?: string, typed?: string): Play =>
  async (ctx) => {
    await sendInCloud(ctx, arm);
    if (typed) await ctx.type(typed, { selector: FIELD });
    else await ctx.focus({ selector: FIELD });
  };

const variant = (note: string, play: Play, fields: Partial<AgentPaneVariant> = {}): AgentPaneVariant => ({
  note,
  ready,
  native,
  nativeDelayMs: { "cloud.startChat": 3_600_000 },
  snapshot: noChat([]),
  play,
  ...fields,
});

export default agentPaneEntry({
  id: "agent-pane.cloud-start-composer",
  title: "Composer while a Cloud chat starts",
  area: "Agent pane",
  experimental: true,
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer"],
  keywords: ["cloud", "start", "composer", "draft", "type ahead", "starting"],
  variants: {
    placeholder: variant(
      "Shipped look: the start is out, the caret is in the open prompt, and the placeholder says what is typed goes to the Cloud chat as a draft. Send rests dimmed.",
      starting("placeholder"),
    ),
    "placeholder-typed": variant(
      "Shipped look, typed ahead: the text stays in the prompt as typed; Send stays dimmed, its tooltip says the text moves to the Cloud chat as a draft.",
      starting("placeholder", TYPED),
    ),
    status: variant("Alternative: the placeholder is a quiet “Starting in Cloud…”, Send dimmed.", starting("status")),
    "status-typed": variant(
      "Alternative, typed ahead: the quiet status gives way to the text.",
      starting("status", TYPED),
    ),
    dimmed: variant(
      "Alternative: the usual placeholder, and the prompt's words at the muted ink until the chat opens.",
      starting("dimmed", TYPED),
    ),
    failed: variant(
      "The start failed: the prompt is back in the composer, the text typed meanwhile after it; Retry sends the prompt alone.",
      async (ctx) => {
        await sendInCloud(ctx);
        await ctx.type(TYPED, { selector: FIELD });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-start[data-state='failed']"), {
          capMs: 10_000,
        });
      },
      {
        native: {
          ...native,
          "cloud.startChat": {
            nativeError: { code: "cloud_start_failed", userMessage: "The machine stopped answering.", retryable: true },
          },
        },
        nativeDelayMs: { "cloud.startChat": 1_500 },
      },
    ),
  },
  experiment: {
    definition: cloudStartComposerLook,
    setup: (ctx) => sendInCloud(ctx),
    script: [{ name: "Type ahead", run: (ctx) => ctx.type(TYPED, { selector: FIELD }) }],
  },
});
