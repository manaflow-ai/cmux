// l10n-allow-file: gallery fixtures (sample prompts, replies and documents), not shipped UI.
// The side preview panel (ArtifactPanel.tsx, cx-ncc.63): a reply's HTML, SVG or Markdown fence has
// Open preview in its code card header (OpenPreview.tsx); the panel opens beside the chat with
// Preview and Code. Off the bundled pane there is no render frame, so HTML shows Code only. A document
// the chat rewrote (same kind and title) steps between its versions in the header (cx-ncc.64).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const fence = (lang: string, code: string) => "```" + lang + "\n" + code + "\n```";

const notes = `# Uploader retry

Uploads now retry **three times**, doubling from 200 ms.

| Failure | Retried |
| --- | --- |
| 5xx | yes |
| Timeout | yes |
| 4xx | no |

- Backoff caps at 1.6 s.
- A cancelled upload never retries.`;

const page = `<!doctype html>
<html>
  <body style="font-family: system-ui; padding: 24px">
    <h2>Pro plan</h2>
    <p>$20 a month, billed yearly.</p>
    <button style="padding: 8px 14px; border-radius: 8px">Upgrade</button>
  </body>
</html>`;

const reply = (prompt: string, text: string) =>
  chat([user(prompt, 6), assistant(text, 5), summary(5, { status: "completed", durationMs: 21_000 })]);

const open = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Open preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact"));
};

const notesV1 = `# Uploader retry

Uploads now retry, doubling from 200 ms.`;

const notesV2 = `# Uploader retry

Uploads now retry **three times**, doubling from 200 ms.

- Backoff caps at 1.6 s.`;

const liveReply = (text: string, version: number, streaming = true) =>
  chat([
    user("Update the release notes while I read the preview", 1),
    assistant(fence("markdown", text), 0, { id: "artifact-live", version, streaming }),
  ]);
const live = (finish = false) => ({
  note: finish
    ? "The preview follows the same source through turn completion."
    : "A live rewrite updates the already-open preview; no close/reopen.",
  snapshot: liveReply(notesV1, 1),
  play: async (ctx: PlayContext) => {
    await open(ctx);
    const page = ctx.document.defaultView as Window;
    page.cmuxAcpmuxBridge?.receive(liveReply(notesV2, 2, !finish));
    await ctx.waitFor(() =>
      [...ctx.document.querySelectorAll(".cv-codeblock")].some((node) => node.textContent?.includes("Backoff caps")),
    );
  },
});

export default agentPaneEntry({
  id: "agent-pane.artifact-panel",
  title: "Side preview panel",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/ArtifactPanel.tsx", "agent-session/acpmux/conversation/OpenPreview.tsx"],
  variants: {
    "live-stream": live(),
    "live-finished": live(true),
    "live-history": {
      ...live(),
      note: "Three saved versions remain available while the chosen live source updates.",
      snapshot: chat([
        assistant(fence("markdown", notes), 4),
        assistant(fence("markdown", notesV1), 3),
        assistant(fence("markdown", notesV2), 0, { id: "artifact-live", version: 2, streaming: true }),
      ]),
      play: open,
    },
    closed: {
      note: "A reply's Markdown fence: Open preview sits in its code card header.",
      snapshot: reply("Write release notes for the retry change", `Here they are:\n\n${fence("markdown", notes)}`),
    },
    markdown: {
      note: "The notes open beside the chat, rendered, with Code a tab away.",
      snapshot: reply("Write release notes for the retry change", `Here they are:\n\n${fence("markdown", notes)}`),
      play: open,
    },
    html: {
      note: "An HTML page: in the bundled pane it draws in the render frame; here it shows Code only.",
      snapshot: reply("Mock the Pro plan card", `A first pass:\n\n${fence("html", page)}`),
      play: open,
    },
    versions: {
      note: "The chat rewrote the notes: the panel opens on the first and steps to the rewrite with < 1/2 >.",
      snapshot: chat([
        user("Write release notes for the retry change", 9),
        assistant(`A first draft:\n\n${fence("markdown", notesV1)}`, 8),
        summary(8, { status: "completed", durationMs: 12_000 }),
        user("Add the retry limit", 7),
        assistant(`Updated:\n\n${fence("markdown", notesV2)}`, 6),
        summary(6, { status: "completed", durationMs: 16_000 }),
        user("Add the failure table", 4),
        assistant(`Updated:\n\n${fence("markdown", notes)}`, 5),
        summary(5, { status: "completed", durationMs: 21_000 }),
      ]),
      play: open,
    },
  },
});
