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

export default agentPaneEntry({
  id: "agent-pane.artifact-panel",
  title: "Side preview panel",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/ArtifactPanel.tsx", "agent-session/acpmux/conversation/OpenPreview.tsx"],
  variants: {
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
        user("Add the failure table", 6),
        assistant(`Updated:\n\n${fence("markdown", notes)}`, 5),
        summary(5, { status: "completed", durationMs: 21_000 }),
      ]),
      play: open,
    },
  },
});
