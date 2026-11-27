// l10n-allow-file: gallery fixtures (sample prompts, commands and messages), not shipped UI.
// A turn that ends with tool rows alone and no words to the person (Leo, 2026-11-27, on a coordinator
// turn that queued two lands and sent a message: "and why did you not have any output there? that's
// fine btw. but we do have a slightly awkward rendering situation here"). His turn: a thought, "Queue
// lands for #60053 and #60188" and a message "Sent to" another lane, then the turn's footer with no
// reply between the work and it. `closed` is the turn as it ends; `open` is its Worked for opened.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "queued\n", exitCode: 0 });
const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `queued for ${to}\n`,
  });

function leosChat(): AcpmuxRow[] {
  return [
    user("Land the two open PRs and hand the rest of the queue to another lane.", 6),
    assistant("I'll queue both lands and ask the distribution lane to take the rest.", 5.9),
    summary(5.8, { status: "completed", durationMs: 4_000, toolCount: 0 }),
    user("go", 2),
    activity(
      [
        thought("Both PRs are green, so queue them and hand the rest off."),
        run("Queue lands for #60053 and #60188", "cmux-gh land 60053 60188"),
        send("distribute-work", "Distribute work off the busy host: take the queue after #60188."),
      ],
      1.98,
    ),
    summary(1.95, { status: "completed", durationMs: 2_800, toolCount: 2 }),
  ];
}

const snapshot = (family: string) => {
  const base = chat(leosChat(), { title: "Turn with no reply", harness: family });
  return { ...base, summary: { ...base.summary!, family } };
};

/// Opens the last turn's Worked for.
const openWorked: Play = async (ctx) => {
  const lines = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")];
  const last = lines().at(-1);
  if (!last || last.getAttribute("aria-expanded") !== "false") return;
  last.click();
  await ctx.waitFor(() => lines().at(-1)?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
};

const variant = (note: string, family: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(family),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.zero-text-turn",
  title: "A turn with tool rows and no reply",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  variants: {
    closed: variant("Leo's 2026-11-27 turn in a Claude chat as it ends: its Worked for, no reply, its footer.", "claude"),
    open: variant("The same turn with its Worked for opened: the thought, the command and the sent message.", "claude", openWorked),
    codex: variant("The same turn in a Codex chat.", "codex"),
  },
});
