// l10n-allow-file: gallery regression fixtures, not shipped UI.
// The permission card's answers (PermissionCard.tsx). Leo 2026-10-25, on a Claude Code ffmpeg ask:
// "the allow button, like this, it shouldn't be encompassing so much. Like I'm pretty sure we can
// have, like, this be, I mean, just always allow. But then this other, like, thing shouldn't be the
// same thing." Always allow held the whole rule as a full-width row, and the rule showed again under
// it. The answers are compact buttons in one row; the rule shows once, as one muted line under them
// (test/agent-pane-permission-card-row.test.ts reads these frames).
import { agentPaneEntry } from "../../gallery/format";
import { activity, chat, CWD, row, tool, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxPermission } from "./model";
import { SHORTCUT_ACTIONS } from "./shortcuts";

/// Leo's ask: Claude Code's Bash call with its long session rule on Always allow.
const ffmpeg: AcpmuxPermission = {
  permissionId: "ffmpeg-contact-sheet",
  title: "`cd ~/scratch/whats-new-video/reel && rm f/*; ffmpeg …`",
  kind: "execute",
  command:
    'cd ~/scratch/whats-new-video/reel && rm f/*; ffmpeg -v error -i reel.mp4 -vf "fps=1,scale=640:-1,tile=4x4" -frames:v 1 sheet.jpg; ls -la sheet.jpg',
  description: "Make a contact sheet of the reel",
  pending: true,
  options: [
    { id: "allow", name: "Allow", kind: "allow_once", allow: true },
    {
      id: "allowAlways",
      name: "Always Allow",
      kind: "allow_always",
      rule: 'Allow //Users/you/scratch/whats-new-video/reel/**, rm f/*, ffmpeg -v error -i reel.mp4 -vf "fps=1,scale=640:-1,tile=4x4" -frames:v 1 sheet.jpg for this session',
      allow: true,
    },
    { id: "reject", name: "Reject", kind: "reject_once", allow: false },
  ],
};

/// A Codex ask: its directory scope, a grant named in words, and a fourth answer of its own.
const codex: AcpmuxPermission = {
  permissionId: "codex-push",
  title: "Run git push origin feat/retries",
  kind: "execute",
  command: "git push origin feat/retries",
  pending: true,
  scope: { kind: "directory", value: CWD },
  options: [
    { id: "approved", name: "Yes", kind: "allow_once", allow: true },
    {
      id: "approved_for_session",
      name: "Yes, and don't ask again for commands that start with `git push`",
      kind: "allow_always",
      allow: true,
    },
    { id: "denied", name: "No, continue without running it", kind: "reject_always", allow: false },
    { id: "abort", name: "No, and tell Codex what to do differently", kind: "reject_once", allow: false },
    { id: "plan", name: "Show me the plan first", kind: "custom", allow: false },
  ],
};

const rows = (permission: AcpmuxPermission) => [
  user("Make a contact sheet of the reel so I can check the cuts", 2),
  activity([tool("List the reel's frames", "execute", "completed")], 1),
  row("permission", 0, { permission }),
];
const trusted = { "acp.trust.get": { cwd: CWD, level: "trusted" } };
/// The app's default keycaps, pushed as the host pushes them (CmuxNextAgentPane AgentPaneShortcuts).
const keycaps = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};
const shown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-ask .acpmux-permission-buttons"));
  const page = ctx.document.defaultView as unknown as {
    cmuxAcpmuxBridge?: { applyShortcuts?(labels: Record<string, string>): void };
  } | null;
  page?.cmuxAcpmuxBridge?.applyShortcuts?.(keycaps);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-ask .acpmux-permission-action-shortcut"));
};

export default agentPaneEntry({
  id: "agent-pane.permission-card",
  title: "Permission card answers",
  area: "Agent pane",
  height: 460,
  widths: { narrow: 420, normal: 820, wide: 1060 },
  covers: ["agent-session/acpmux/PermissionCard.tsx#PermissionCard"],
  keywords: ["allow once", "always allow", "deny", "permission", "rule"],
  variants: {
    "claude-long-rule": { snapshot: chat(rows(ffmpeg), { permission: ffmpeg }), native: trusted, play: shown },
    "codex-five-options": {
      snapshot: chat(rows(codex), { permission: codex, harness: "codex", model: "gpt-6-astra" }),
      native: trusted,
      play: shown,
    },
  },
});
