// l10n-allow-file: sample completed tool records, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxActivity } from "../model";

const page = `<!doctype html><html><title>Weather</title><body>
<h1>Weather</h1><p>Sunny, 24°</p><ul><li>Wind: 8 km/h</li><li>Rain: 0 mm</li></ul>
</body></html>`;
const rawWrite = (title: string, field: string) =>
  tool(title, "edit", "completed", {
    inputSummary: JSON.stringify({ [field]: "weather.html", content: page }),
    // Unknown old contents do not turn this complete recorded Write into a snippet.
    diffs: [{ path: "weather.html", newText: page, fragment: true }],
  });
const state = (harness: string, recorded: AcpmuxActivity) =>
  chat([user("Build an HTML weather card", 6), activity([recorded], 5), summary(5, { status: "completed" })], {
    harness,
  });
const reveal = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Worked for 42s" });
};
const preview = async (ctx: PlayContext) => {
  await reveal(ctx);
  await ctx.click({ role: "button", name: "Open preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-artifact"));
};

export default agentPaneEntry({
  id: "agent-pane.artifact-writes",
  title: "Recorded HTML artifacts",
  area: "Agent pane",
  height: 640,
  checks: {
    layoutShiftMax: {
      value: 0.2,
      reason:
        "The play explicitly expands a tool group and opens the side panel, which reflows the transcript and composer. The assertions test whole-document detection, not a stationary layout during these clicks.",
    },
  },
  covers: [
    "agent-session/acpmux/conversation/artifactWrites.ts",
    "agent-session/acpmux/conversation/writtenArtifacts.tsx",
  ],
  variants: {
    claude: {
      note: "Claude's completed whole Write retains its full input despite an unknown-old diff.",
      snapshot: state("claude", rawWrite("Write", "file_path")),
      play: preview,
    },
    codex: {
      note: "Codex's complete normalized ACP diff uses the same preview; no harness-name check.",
      snapshot: state(
        "codex",
        tool("apply_patch", "fileChange", "completed", { diffs: [{ path: "weather.html", newText: page }] }),
      ),
      play: preview,
    },
    pi: {
      note: "pi's recorded whole write uses path/content.",
      snapshot: state("pi", rawWrite("write", "path")),
      play: preview,
    },
    gemini: {
      note: "Gemini's recorded whole write uses file_path/content.",
      snapshot: state("gemini", rawWrite("write_file", "file_path")),
      play: preview,
    },
    "legacy-edit": {
      note: "A replacement-only legacy Edit is a snippet, not an entire document to preview.",
      snapshot: state(
        "claude",
        tool("Edit", "edit", "completed", { diffs: [{ path: "weather.html", newText: "<p>Sunny, 24°</p>" }] }),
      ),
      play: async (ctx) => {
        await reveal(ctx);
        if (ctx.document.querySelector('button[aria-label="Open preview"]'))
          throw new Error("A legacy edit snippet must not offer a whole-document preview");
      },
    },
  },
});
