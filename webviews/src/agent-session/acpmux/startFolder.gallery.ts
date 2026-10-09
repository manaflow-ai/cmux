// l10n-allow-file: gallery fixtures (sample chats and paths), not shipped UI.
// Where a new chat starts (startFolder.tsx, cx-nn3e): picking the home folder asks once, above the
// composer in the place of the private-folder line, before any chat starts there. The host answers
// `workspace.useFolder` with the question; Send waits until the user answers.
import { agentPaneEntry } from "../../gallery/format";
import { noChat, session } from "../../gallery/fixtures/acpmux";

const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481";

const fresh = noChat(
  [
    session({ sessionId: "home", title: "An older chat in the home folder", cwd: "/Users/you" }),
    session({ sessionId: "cmux", title: "Fix the sidebar", cwd: "/Users/you/src/cmux" }),
  ],
  { summary: { sessionId: "", cwd: AGENT_HOME, harness: "claude", model: "claude-opus-5-5", effort: "high" } },
);

export default agentPaneEntry({
  id: "agent-pane.start-folder",
  title: "Start folder question",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  checks: {
    anchorMovePx: {
      value: 64,
      reason: "The question replaces the one-line private-folder note and may wrap, so the composer moves by its extra lines.",
    },
    layoutShiftMax: {
      value: 0.1,
      reason: "The question appears above the composer after the pick, a bounded shift by design.",
    },
  },
  covers: ["agent-session/acpmux/startFolder.tsx#StartFolderAsk"],
  variants: {
    "home-question": {
      note: "Play: pick ~ from the folder menu; the question replaces the private-folder line, with Use Home Folder and Use Private Folder.",
      ready: { newSession: true, chooseFolder: true },
      native: { "workspace.useFolder": { status: "confirm", reason: "home", cwd: "/Users/you" } },
      snapshot: fresh,
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
        await ctx.click({ role: "menuitemradio", name: /\/Users\/you$/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-start-folder-ask"));
      },
    },
    "root-refused": {
      note: "Play: a pick the host refuses (/ or a folder above home): the line says chats cannot start there and offers only the private folder.",
      ready: { newSession: true, chooseFolder: true },
      native: { "workspace.useFolder": { status: "refused", reason: "root", cwd: "/" } },
      snapshot: fresh,
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
        await ctx.click({ role: "menuitemradio", name: /\/Users\/you$/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-start-folder-ask"));
      },
    },
  },
});
