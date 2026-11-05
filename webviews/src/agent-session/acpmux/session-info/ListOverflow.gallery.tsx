// l10n-allow-file: gallery fixtures (sample commands and agents), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { SessionInfoPanel } from "./SessionInfo";
import { TasksSection } from "./TasksSection";
import { ServersSection } from "./ServersSection";
import { SubagentsSection } from "./SubagentsSection";
import type { Subagent } from "../subagents/subagentFold";

type Props = { section: "tasks" | "servers" | "subagents" };
const tasks = Array.from({ length: 40 }, (_, index) => ({
  id: `task-${index}`,
  command: `bun test package-${index}`,
  state: "running" as const,
  startedAt: minutesAgo(index + 1),
}));
const servers = tasks.map((task, index) => ({
  ...task,
  command: `bun run dev --port ${3000 + index}`,
  ports: [3000 + index],
}));
const agents: Subagent[] = tasks.map((task, index) => ({
  id: `agent-${index}`,
  parent: null,
  name: `Review package ${index}`,
  task: task.command,
  state: "completed",
  startedAt: task.startedAt,
  endedAt: minutesAgo(1),
}));
const waiting = new Set<string>();

function ListOverflow({ section }: Props) {
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <SessionInfoPanel width={320} placement="overlay">
        <div className="acpmux-session-info__body" data-layout="glance">
          {section === "tasks" && <TasksSection commands={tasks} />}
          {section === "servers" && <ServersSection servers={servers} />}
          {section === "subagents" && <SubagentsSection agents={agents} waiting={waiting} />}
        </div>
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.session-info-list-overflow",
  title: "Session Info capped lists",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 360, normal: 600 },
  covers: [
    "agent-session/acpmux/session-info/TasksSection.tsx#TasksSection",
    "agent-session/acpmux/session-info/ServersSection.tsx#ServersSection",
    "agent-session/acpmux/session-info/SubagentsSection.tsx#SubagentsSection",
  ],
  load: async () => ListOverflow,
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  variants: {
    tasks: { note: "Forty background tasks scroll within their section.", props: { section: "tasks" } },
    servers: { note: "Forty development servers scroll within their section.", props: { section: "servers" } },
    subagents: {
      note: "The expanded ended-agents list scrolls within its section.",
      props: { section: "subagents" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-subagents__ended" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-subagents__list"));
      },
    },
  },
});
