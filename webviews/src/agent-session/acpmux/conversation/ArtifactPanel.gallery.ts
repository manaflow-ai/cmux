// l10n-allow-file: gallery fixtures (sample prompts, replies and documents), not shipped UI.
// The side preview panel (ArtifactPanel.tsx, cx-ncc.63): a reply's HTML, SVG or Markdown fence has
// Open preview in its code card header (OpenPreview.tsx); the panel opens beside the chat with
// Preview and Code. Off the bundled pane there is no render frame, so HTML shows Code only. A document
// the chat rewrote (same kind and title) steps between its versions in the header (cx-ncc.64).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
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

const counters = [1, 2, 3].map(
  (version) => `<title>Counter</title>
<h1>Counter</h1><p>Revision ${version}: add ${version} per click.</p>
<button onclick="this.textContent = Number(this.textContent) + ${version}">0</button>`,
);
const counterChat = chat(
  counters.flatMap((code, index) => [
    user(`Revise the counter, version ${index + 1}`, 12 - index * 3),
    assistant(fence("html", code), 11 - index * 3),
    summary(11 - index * 3, { status: "completed", durationMs: 3000 }),
  ]),
);
const counterVersion = (index: number) => ({
  note: `Interactive HTML revision ${index + 1} of 3; Run explicitly enables scripts.`,
  snapshot: counterChat,
  play: async (ctx: PlayContext) => {
    await open(ctx);
    for (let step = 0; step < index; step++) await ctx.click({ role: "button", name: "Next version" });
    await ctx.click({ role: "button", name: "Run" });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact-frame"));
  },
});

// A finished edit to counter.html (artifactWrites.ts): Gemini's replace and OpenCode's edit record the
// whole old and new file, which opens; Claude Code's Edit records only its replacement, which never does.
const editChat = (harness: string, name: string, fields: Parameters<typeof tool>[3]) =>
  chat(
    [
      user("Make the counter add 2 per click", 6),
      activity([tool(name, "edit", "completed", fields)], 5),
      summary(5, { status: "completed" }),
    ],
    { harness },
  );
const counterPage = (step: number) => `<!doctype html>
<html>
  <body style="font-family: system-ui; padding: 24px">
    <h1>Counter</h1><p>Adds ${step} per click.</p>
    <button onclick="this.textContent = Number(this.textContent) + ${step}">0</button>
  </body>
</html>`;
const expand = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Worked for 42s" });
};
const editVariants = {
  "edit-complete": {
    note: "OpenCode's finished edit records the whole file: Open sits under the row.",
    snapshot: editChat("opencode", "edit", {
      inputSummary: JSON.stringify({ filePath: "counter.html", oldString: "Adds 1", newString: "Adds 2" }),
      diffs: [{ path: "counter.html", oldText: counterPage(1), newText: counterPage(2) }],
    }),
    play: expand,
  },
  "replace-complete": {
    note: "Gemini's finished replace records the whole file: Open sits under the row.",
    snapshot: editChat("gemini", "replace", {
      inputSummary: JSON.stringify({ file_path: "counter.html", old_string: "Adds 1", new_string: "Adds 2" }),
      diffs: [{ path: "counter.html", oldText: counterPage(1), newText: counterPage(2) }],
    }),
    play: expand,
  },
  "edit-complete-open": {
    note: "Open on OpenCode's finished edit shows the whole edited page.",
    snapshot: editChat("opencode", "edit", {
      inputSummary: JSON.stringify({ filePath: "counter.html", oldString: "Adds 1", newString: "Adds 2" }),
      diffs: [{ path: "counter.html", oldText: counterPage(1), newText: counterPage(2) }],
    }),
    play: async (ctx: PlayContext) => {
      await expand(ctx);
      await open(ctx);
      await ctx.click({ role: "button", name: "Run" });
    },
  },
  "edit-snippet": {
    note: "Claude Code's Edit records only its replacement, not the page: no Open.",
    snapshot: editChat("claude", "Edit counter.html", {
      inputSummary: JSON.stringify({ file_path: "counter.html", old_string: "Adds 1", new_string: "Adds 2" }),
      diffs: [{ path: "counter.html", oldText: "<p>Adds 1 per click.</p>", newText: "<p>Adds 2 per click.</p>" }],
    }),
    play: expand,
  },
};

export default agentPaneEntry({
  id: "agent-pane.artifact-panel",
  title: "Side preview panel",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/ArtifactPanel.tsx",
    "agent-session/acpmux/conversation/artifactPin.ts",
    "agent-session/acpmux/conversation/OpenPreview.tsx",
    "agent-session/acpmux/conversation/writtenArtifacts.tsx",
  ],
  variants: {
    ...Object.fromEntries(
      [
        ["claude", "Write"],
        ["codex", "apply_patch"],
        ["pi", "write"],
        ["gemini", "write_file"],
      ].map(([harness, name]) => [
        `${harness}-write`,
        {
          snapshot: chat(
            [
              user("Write counter.html", 6),
              activity(
                [tool(name!, "edit", "completed", { diffs: [{ path: "counter.html", newText: counters[0]! }] })],
                5,
              ),
              summary(5, { status: "completed" }),
            ],
            { harness },
          ),
          play: async (ctx: PlayContext) => {
            await ctx.click({ role: "button", name: "Worked for 42s" });
            await open(ctx);
            await ctx.click({ role: "button", name: "Run" });
          },
        },
      ]),
    ),
    ...editVariants,
    svg: {
      snapshot: reply(
        "Draw a circle",
        fence("svg", '<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40" fill="seagreen"/></svg>'),
      ),
      play: open,
    },
    "interactive-v1": counterVersion(0),
    "interactive-v2": counterVersion(1),
    "interactive-v3": counterVersion(2),
    "jsx-fragment": {
      snapshot: reply(
        "Make a counter button",
        fence("jsx", '<button onClick={event => event.currentTarget.textContent = "1"}>0</button>'),
      ),
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ role: "button", name: "Run" });
      },
    },
    jsx: {
      note: "Offline React hooks in an isolated JSX artifact, after Run.",
      snapshot: reply(
        "Build a React counter",
        fence(
          "jsx",
          'import { useState } from "react"; export default function Counter() { const [n, setN] = useState(0); return <button onClick={() => setN(n + 1)}>Count {n}</button>; }',
        ),
      ),
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ role: "button", name: "Run" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact-frame"));
      },
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
      note: "An HTML page: in the bundled pane it draws in the render frame; the gallery renders the same offline document.",
      snapshot: reply("Mock the Pro plan card", `A first pass:\n\n${fence("html", page)}`),
      play: open,
    },
    pinned: {
      note: "A person pins the preview and sees its owning conversation next to the document, with an explicit Unpin control.",
      snapshot: chat(
        [
          user("Write the retry review", 6),
          assistant(`The review is here:\n\n${fence("markdown", notes)}`, 5),
          summary(5, { status: "completed", durationMs: 21_000 }),
        ],
        { title: "Retry review" },
      ),
      play: async (ctx: PlayContext) => {
        await open(ctx);
        await ctx.click({ selector: '.acpmux-artifact-actions button[aria-label="Pin"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact-source"));
      },
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
