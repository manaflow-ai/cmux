// l10n-allow-file: background-command and subagent fixtures for the parity workbench.
import { agentPaneEntry, type AgentPaneVariant } from "../format";
import { GALLERY_NOW, minutesAgo } from "../clock";
import { activity, assistant, chat, row, tool, user } from "../fixtures/acpmux";
import { SUBAGENTS } from "../../agent-session/acpmux/subagents/subagentFold";

const commands = [
  ["sleep 300", "NewInNewGroupRowSlotTests on base"],
  ["git push origin HEAD:compile-check", "scratch push + compile-check of rebase"],
  ["swift test --filter NewInNewGroupRowSlotTests", "Green Swift step result"],
  ["git push origin HEAD:slot-tests", "scratch push + compile-check of rebased slot tests"],
  ["git push origin HEAD:new-workspace-top", "push of new-workspace-top fix to feature branch"],
] as const;

export function backgroundWorkSnapshot(mixed = false, completed = true) {
  return chat(
    [
      user("Check the workspace changes and keep the background commands visible.", 24),
      ...(mixed
        ? [
            row(SUBAGENTS, 23, {
              subagents: [
                {
                  id: "background-claude",
                  parent: null,
                  name: "Review the Swift change",
                  harness: "claude",
                  state: "running",
                  startedAt: minutesAgo(23),
                },
                {
                  id: "background-codex",
                  parent: null,
                  name: "Check the command results",
                  harness: "codex",
                  state: "running",
                  startedAt: minutesAgo(22),
                },
              ],
            }),
          ]
        : []),
      activity(
        commands.map(([command, description], index) =>
          tool(command, "execute", "completed", {
            id: `background-command-${index}`,
            command,
            inputSummary: JSON.stringify({ command, description, run_in_background: true }),
            startedAt: minutesAgo(20 + index),
            background:
              !completed || index === 0
                ? { state: "running" }
                : { state: "completed", endedAt: GALLERY_NOW - index * 10_000 },
          }),
        ),
        20,
      ),
      assistant(
        completed ? "Four commands finished. One wait is still running." : "The background commands are running.",
        1,
      ),
    ],
    { title: mixed ? "Commands and agent logos" : "Background commands / one wait and four done", isWorking: true },
  );
}

const variant = (mixed: boolean): AgentPaneVariant => ({
  note: mixed
    ? "One terminal header icon alongside Claude and Codex logos. Every command and subagent keeps its own row."
    : "The screenshot's one wait and four completed commands, expanded. The header shows one terminal icon.",
  snapshot: backgroundWorkSnapshot(mixed, false),
  play: async ({ document, waitFor, click }) => {
    await waitFor(() => document.querySelector(".acpmux-running-tray__head"));
    if (document.querySelector(".acpmux-running-tray__head")!.getAttribute("aria-expanded") !== "true")
      await click({ selector: ".acpmux-running-tray__head" });
    await waitFor(
      () => document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === (mixed ? 7 : 5),
    );
    // Let the real tray observe the commands running before their completion snapshots arrive.
    // Transcript-only task ends have no registry timestamp, so only observed work can linger.
    const bridge = document.defaultView?.cmuxAcpmuxBridge;
    if (!bridge) throw new Error("The agent-pane fixture bridge is missing");
    bridge.receive(backgroundWorkSnapshot(mixed));
    await waitFor(
      () => document.querySelectorAll('.acpmux-running-tray .acpmux-agent-line[data-status="done"]').length === 4,
    );
    await waitFor(
      () => document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === (mixed ? 7 : 5),
    );
    if (document.querySelectorAll('.acpmux-running-tray__stack [data-icon="terminal"]').length !== 1)
      throw new Error("Commands must share one terminal header icon");
    if (mixed && document.querySelectorAll(".acpmux-running-tray__stack .agent-mark").length !== 2)
      throw new Error("Both subagent harness logos must appear");
  },
});

export default agentPaneEntry({
  id: "agent-pane.parity-background-work",
  title: "Background commands and agent logos",
  area: "Agent pane",
  height: 680,
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx"],
  variants: { commands: variant(false), mixed: variant(true) },
});
