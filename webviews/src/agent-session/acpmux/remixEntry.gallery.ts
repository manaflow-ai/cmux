// l10n-allow-file: gallery fixtures, not shipped UI.
// Fork and customize (cmux.com's button on an extension page, `cmux://build?remix=REF`): the app
// opens a new chat whose composer holds the remix ask, unsent (CmuxNextActions DeepLink+Build.swift
// `remixDraft`); the person types what to change and presses Return. The agent then runs
// `cmux ext remix REF` and, when it works, `cmux ext share` (on by default) to publish it to a new
// GitHub repository of theirs (cmux-tui `cli/ext/remix.rs`, `share.rs`).
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { CWD, noChat } from "../../gallery/fixtures/acpmux";

const REF = "github.com/acme/cmux-todo@0123456789abcdef0123456789abcdef01234567";
/// DeepLink+Build.swift `remixDraft(REF)`.
const DRAFT = `Fork and customize ${REF}: run \`cmux ext remix ${REF}\` and do what it prints. What I want changed: `;

const holdsTheAsk = async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector(".acpmux-composer [contenteditable='true'], .nt-field");
    return field?.textContent?.includes("cmux ext remix") ?? false;
  });
};

const typesTheChange = async (ctx: PlayContext) => {
  await holdsTheAsk(ctx);
  await ctx.type("show overdue items in red and add a due-today count");
  await ctx.waitFor(() => ctx.document.body.textContent?.includes("due-today count") ?? false);
};

export default agentPaneEntry({
  id: "agent-pane.remix-entry",
  title: "Fork and customize opens a chat with the remix ask ready",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 720, wide: 1000 },
  covers: ["agent-session/acpmux/Composer.tsx"],
  variants: {
    "a-chat-dock": {
      note: "Picked: the link opens New Agent Chat's own new chat with the ask in its composer, unsent; nothing runs until Return.",
      ready: { newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: holdsTheAsk,
    },
    "a-chat-dock-change": {
      note: "The person adds what to change after the ask: one Return from the remix.",
      ready: { newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: typesTheChange,
    },
    "b-quick-composer": {
      note: "Compared: the Start Agent panel over the app. The chat goes to the sidebar in the background after Return.",
      ready: { surface: "quick", newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: holdsTheAsk,
    },
    "c-new-tab-page": {
      note: "Compared: the New Tab page in the focused pane.",
      ready: {
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: CWD,
          home: "/Users/you",
          lastAgent: "claude",
          template: "minimal",
          draft: DRAFT,
        },
        newSession: true,
      },
      snapshot: noChat([]),
      play: holdsTheAsk,
    },
  },
});
