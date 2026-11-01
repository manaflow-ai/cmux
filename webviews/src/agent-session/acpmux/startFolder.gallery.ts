// l10n-allow-file: gallery fixtures (sample chats and paths), not shipped UI.
// Where a new chat starts (startFolder.tsx, cx-nn3e): picking the home folder asks once, above the
// composer in the place of the private-folder line, before any chat starts there. The host answers
// `workspace.useFolder` with the question; Send waits until the user answers.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { noChat, session } from "../../gallery/fixtures/acpmux";

const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481";

const WORKTREE = "/Users/you/.cmux/worktrees/cmux/fix-sidebar";

/// A new chat in a project folder: New Worktree is an action in its folder menu (cx-lyqio.2).
// A new chat (no session yet: the summary's empty id matches the snapshot's), so it offers New Worktree.
const inProject = noChat([session({ sessionId: "cmux", title: "Fix the sidebar", cwd: "/Users/you/src/cmux" })], {
  sessionId: "",
  summary: { sessionId: "", cwd: "/Users/you/src/cmux", harness: "claude", model: "claude-opus-5-5", effort: "high" },
});

const newWorktree: Play = async (ctx) => {
  await ctx.click({ selector: '[aria-label="Folder"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
  await ctx.click({ role: "option", name: "New Worktree" });
};

// The home folder's row in the folder menu. Rows show the repository or folder name since #22724,
// with the full path only as the row's tooltip.
const HOME_ROW = '.acpmux-location-menu [title="/Users/you"]';

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
      reason:
        "The question replaces the one-line private-folder note and may wrap, so the composer moves by its extra lines.",
    },
    layoutShiftMax: {
      value: 0.1,
      reason: "The question appears above the composer after the pick, a bounded shift by design.",
    },
  },
  covers: [
    "agent-session/acpmux/startFolder.tsx#StartFolderAsk",
    "agent-session/acpmux/startFolder.tsx#WorktreeFailure",
  ],
  variants: {
    "home-question": {
      note: "Play: pick ~ from the folder menu; the question replaces the private-folder line, with Use Home Folder and Use Private Folder.",
      ready: { newSession: true, chooseFolder: true },
      native: { "workspace.useFolder": { status: "confirm", reason: "home", cwd: "/Users/you" } },
      snapshot: fresh,
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
        await ctx.click({ selector: HOME_ROW });
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
        await ctx.click({ selector: HOME_ROW });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-start-folder-ask"));
      },
    },
    "new-worktree": {
      note: "Play: New Worktree from a new chat's folder menu; the host makes the worktree on its own branch and the chat starts there (the folder chip names it).",
      ready: { newSession: true },
      native: {
        "git.worktree.create": {
          value: { root: WORKTREE, branch: "cmux/fix-sidebar", base: "main", base_commit: "4f2a9c1" },
          replayed: false,
        },
        "workspace.useFolder": { status: "ok", cwd: WORKTREE },
      },
      snapshot: inProject,
      play: async (ctx) => {
        await newWorktree(ctx);
        await ctx.waitFor(() =>
          ctx.document.querySelector('[aria-label="Folder"]')?.textContent?.includes("fix-sidebar"),
        );
      },
    },
    "worktree-creating": {
      note: "Play: New Worktree while the host is still making it: the line above the composer says Creating worktree…, then the chat starts there.",
      ready: { newSession: true },
      native: {
        "git.worktree.create": {
          value: { root: WORKTREE, branch: "cmux/fix-sidebar", base: "main", base_commit: "4f2a9c1" },
          replayed: false,
        },
        "workspace.useFolder": { status: "ok", cwd: WORKTREE },
      },
      nativeDelayMs: { "git.worktree.create": 1500 },
      snapshot: inProject,
      play: async (ctx) => {
        await newWorktree(ctx);
        await ctx.waitFor(() =>
          ctx.document.querySelector(".acpmux-worktree-creating")?.textContent?.includes("Creating worktree"),
        );
        await ctx.waitFor(() =>
          ctx.document.querySelector('[aria-label="Folder"]')?.textContent?.includes("fix-sidebar"),
        );
        if (ctx.document.querySelector(".acpmux-worktree-creating"))
          throw new Error("the creating line outlived the worktree");
      },
    },
    "worktree-refused": {
      note: "Play: a New Worktree the host does not make: the chat keeps its folder and the line above the composer says why, with Dismiss.",
      ready: { newSession: true },
      snapshot: inProject,
      play: async (ctx) => {
        await newWorktree(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]'));
      },
    },
  },
});
