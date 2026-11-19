// l10n-allow-file: gallery fixtures (dialogs read off a terminal: commands, paths, option labels), not shipped UI.
// Toggle Terminal and Chat's approval (terminalApproval.ts): while the terminal drives the session,
// the harness's own dialog, read off the terminal's screen (cmux-window-rules tabs::approval), shows
// in the chat as the chat's permission card (PermissionCard.tsx, no new look) and a click picks that
// option in the terminal. Leo, 2026-11-12: the toggle is "the sauce", two live views of one session.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "../shortcuts";
import { TerminalApprovalAsk } from "./TerminalApprovalAsk";
import type { TerminalApproval } from "./terminalApproval";

type Props = { approval: TerminalApproval };

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
};

/// Claude Code's Bash dialog: Yes, Yes and don't ask again, No.
const claudeThree: TerminalApproval = {
  id: "6f1c2a9e0b4d7735",
  question: "Do you want to proceed?",
  header: "Bash command",
  command: "touch /tmp/w4i-perm",
  detail: ["Create an empty marker file"],
  options: [
    { key: 1, label: "Yes", kind: "allow_once" },
    { key: 2, label: "Yes, and don't ask again for touch commands in /private/tmp", kind: "allow_always" },
    { key: 3, label: "No, and tell Claude what to do differently", kind: "reject_once" },
  ],
  harness: "claude",
};

/// Codex's command approval: the question first, then its reason and command.
const codex: TerminalApproval = {
  id: "a03e5d7c912b4f60",
  question: "Would you like to run the following command?",
  command: "cargo test -p acpmux resume_here",
  detail: ["Reason: Run the tests outside the sandbox"],
  options: [
    { key: 1, label: "Yes, proceed", kind: "allow_once" },
    { key: 2, label: "Yes, and don't ask again for this command", kind: "allow_always" },
    { key: 3, label: "No, and tell Codex what to do differently", kind: "reject_once" },
  ],
  harness: "codex",
};

/// A long command: clamped to its first line, the whole one a click away.
const longCommand: TerminalApproval = {
  id: "4b8d0e2f6a1c9357",
  question: "Do you want to proceed?",
  header: "Bash command",
  command:
    "ffmpeg -y -i /Users/you/media/launch-reel/raw/take-03.mov -vf scale=1280:-2 -c:v libx264 -crf 20 /Users/you/media/launch-reel/out/take-03.mp4 && rm -f /Users/you/media/launch-reel/raw/*.tmp",
  detail: ["Encode the take and remove the temporary files"],
  options: [
    { key: 1, label: "Yes", kind: "allow_once" },
    { key: 2, label: "No, and tell Claude what to do differently", kind: "reject_once" },
  ],
  harness: "claude",
};

/// Claude Code's edit dialog: no command, the file as what it touches.
const claudeEdit: TerminalApproval = {
  id: "d92f7a3c5e081b46",
  question: "Do you want to make this edit to main.rs?",
  header: "Edit file",
  detail: ["src/main.rs"],
  options: [
    { key: 1, label: "Yes", kind: "allow_once" },
    { key: 2, label: "Yes, allow all edits during this session", kind: "allow_always" },
    { key: 3, label: "No, and tell Claude what to do differently", kind: "reject_once" },
  ],
  harness: "claude",
};

function GalleryTerminalApproval({ approval }: Props) {
  return (
    <div className="acpmux-shell" style={{ paddingTop: 12 }}>
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <ShortcutsContext value={labels}>
            <TerminalApprovalAsk approval={approval} />
          </ShortcutsContext>
        </div>
      </div>
    </div>
  );
}

/// The card is the chat's own permission card, with one button per answer the dialog offers.
const sameCard: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-ask"));
  if (ctx.document.querySelectorAll(".acpmux-permission-buttons button").length < 2)
    throw new Error("The card lost the dialog's answers");
};

export default componentEntry<Props>({
  id: "agent-pane.terminal-approval",
  title: "Terminal approval in the chat",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/terminalApproval/TerminalApprovalAsk.tsx#TerminalApprovalAsk"],
  load: async () => GalleryTerminalApproval,
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../keys.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 260,
  variants: {
    "claude-three": {
      note: "Claude Code's Bash dialog read off the terminal: Yes, Yes and don't ask again, No.",
      props: { approval: claudeThree },
      play: sameCard,
    },
    codex: {
      note: "Codex's command approval: its reason as what the call does, its command in the details band.",
      props: { approval: codex },
      play: sameCard,
    },
    "long-command": {
      note: "A long command, clamped to its first line with the full command one click away.",
      props: { approval: longCommand },
      play: sameCard,
    },
    "claude-edit": {
      note: "Claude Code's edit dialog: no command, the file it edits.",
      props: { approval: claudeEdit },
      play: sameCard,
    },
  },
});
