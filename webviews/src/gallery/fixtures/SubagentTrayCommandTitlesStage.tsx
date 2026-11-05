// l10n-allow-file: gallery fixtures (commands, descriptions, subagent tasks), not shipped UI.
// The running tray's background command lines (SubagentTrayCommandTitles.gallery.ts): each scene is
// the tray open over the commands as acpmux's process registry lists them, so a line's owner (a
// subagent's call started it) and its description are what the registry says.
import type { CSSProperties } from "react";
import type { BackgroundCommand } from "../../agent-session/acpmux/session-info/processes";
import { trayItems } from "../../agent-session/acpmux/subagents/runningTray";
import { SubagentTray } from "../../agent-session/acpmux/subagents/SubagentTray";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import { minutesAgo } from "../clock";

const NO_WAITING: ReadonlySet<string> = new Set();
const shown = { current: "gallery-chat" as string | undefined };

export type CommandTitlesScene = "terse" | "long" | "none" | "subagent";

const reviewer: Subagent = {
  id: "gallery-chat/toolu_reviewer",
  parent: null,
  name: "Reviewer",
  task: "Review the tray PR at its head",
  kind: "general-purpose",
  state: "running",
  background: true,
  startedAt: minutesAgo(3),
};

let next = 0;
const command = (line: string, description: string | undefined, seconds: number, subagent?: string) => {
  next += 1;
  return {
    id: `gallery-chat/b${next}`,
    command: line,
    ...(description ? { description } : {}),
    ...(subagent ? { subagent } : {}),
    state: "running",
    processId: `gallery-chat/b${next}`,
    toolCallId: `toolu_gallery_${next}`,
    startedAt: Date.now() - seconds * 1000,
  } satisfies BackgroundCommand;
};

const WAIT_FILE =
  "until [ -s /tmp/claude/tasks/b0luhqojj.output ]; do sleep 5; done; cat /tmp/claude/tasks/b0luhqojj.output";

const SCENES: Record<CommandTitlesScene, { agents: Subagent[]; commands: BackgroundCommand[] }> = {
  // The agent named its Monitor calls "hold" and "review result": the line says what each does first.
  terse: {
    agents: [],
    commands: [
      command("sleep 840; echo t", "hold", 8),
      command("sleep 600; echo t", "hold", 19),
      command(WAIT_FILE, "review result", 23),
      command("gh pr checks 34260 --watch", "checks", 37),
    ],
  },
  long: {
    agents: [],
    commands: [
      command(
        "gh pr view 3119 -R manaflow-ai/cmux --json body --jq .body | grep -n '^HOLD:'",
        "Check PR #3119 for a HOLD line before landing it",
        12,
      ),
      command("cd ~/Projects/app/webviews && bun test --watch", "Watch the composer tests", 40),
    ],
  },
  none: {
    agents: [],
    commands: [
      command("sleep 840; echo t", undefined, 8),
      command(WAIT_FILE, undefined, 23),
      command("cd ~/Projects/app && npm run lint -- --max-warnings 0", undefined, 31),
    ],
  },
  subagent: {
    agents: [reviewer],
    commands: [
      command("sleep 840; echo t", "hold", 8, reviewer.id),
      command(WAIT_FILE, "review result", 23, reviewer.id),
      command("cd ~/Projects/app && bun run dev", "Run the dev server", 50),
    ],
  },
};

export function SubagentTrayCommandTitlesStage({ scene }: { scene: CommandTitlesScene }) {
  const { agents, commands } = SCENES[scene];
  const items = trayItems(agents, commands, [], true);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <main className="acpmux-main" data-dock="float" style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div className="acpmux-dock" style={{ "--cv-inset": "16px" } as CSSProperties}>
          <SubagentTray
            key={`gallery-chat-${scene}`}
            items={items}
            working
            waiting={NO_WAITING}
            onOpen={() => undefined}
            stopProcess={() => Promise.resolve()}
            shown={shown}
          />
          <div className="acpmux-composer">
            <div className="acpmux-composer-box" style={{ minHeight: 56 }} />
          </div>
        </div>
      </main>
    </div>
  );
}
