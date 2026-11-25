// l10n-allow-file: gallery fixtures for the live spot's statuses.
// Every status the live spot can show, each under the one shimmer (scenarios ST-03 and ST-04; Leo,
// 2026-11-22: "you sending messages or whatever aren't being accounted properly a la the "thinking"
// thing", "the "waiting" also shouldnt be special cased as white. all in the "thinking" spot should
// glimmer like that"). The real Thinking line (Thinking.tsx) for each label it can say, then the
// activity line (ActivityLine.tsx) for each of its kinds. Light and dark from the gallery's shared
// controls; `glass` draws them on a glass card as a glass theme does.
import type { ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { ActivityLine } from "./ActivityLine";
import type { LiveWait } from "./liveWait";
import { Thinking } from "./Thinking";
import { type WaitingOn, WaitingOnContext } from "./waitingOn";

type Props = { surface?: "plain" | "glass" };

const NOW = 64_000;
const now = () => NOW;
const line: AcpmuxRow = { id: "activityLine-p", version: 1, at: 0, kind: "activityLine", below: true };

const wait = (waiting: WaitingOn, node: ReactNode) => <WaitingOnContext value={waiting}>{node}</WaitingOnContext>;

// What a silent line waits on (liveWait.ts): never a bare "Waiting" (Leo, 2026-11-22: "everything
// that goes in there write more detailed things than just waiting").
const WAITS: [string, LiveWait | undefined][] = [
  ["Waiting: after a step", { kind: "step", step: "Ran bun test" }],
  ["Waiting: first reply", { kind: "prompt" }],
  ["Waiting: a message", { kind: "message", from: "picker" }],
  ["Waiting: queued", { kind: "queued" }],
  ["Waiting: next step", { kind: "next" }],
  ["Waiting: unknown", undefined],
];

const STATUSES: [string, ReactNode][] = [
  ["Thinking", <Thinking key="k36" since={0} now={now} />],
  ["Step", <Thinking key="k37" since={0} now={now} doing="Read App.tsx" doingAt={40_000} turnTotal />],
  ["Command", <Thinking key="k38" since={0} now={now} doing="bun test" doingShell doingAt={50_000} turnTotal />],
  ["Writing a command", <Thinking key="k39" since={0} now={now} doing="" doingShell draft turnTotal />],
  [
    "Sending",
    <Thinking key="k40" since={0} now={now} doing="SendMessage" sendTo="Prioritize visible cmux" doingAt={60_000} />,
  ],
  ["Writing", <Thinking key="k41" since={0} now={now} liveState="writing" quietKey="r:1" quietAt={NOW} turnTotal />],
  ["Subagents", <Thinking key="k42" since={0} now={now} liveState="subagents" liveAgents={2} turnTotal />],
  [
    "Subagent, named",
    <Thinking
      key="k45"
      since={0}
      now={now}
      liveState="subagents"
      liveAgents={1}
      liveAgentNames={["Explore auth flow"]}
      turnTotal
    />,
  ],
  [
    "Subagents, named",
    <Thinking
      key="k56"
      since={0}
      now={now}
      liveState="subagents"
      liveAgents={2}
      liveAgentNames={["lint", "tests"]}
      turnTotal
    />,
  ],
  [
    "Subagents, more",
    <Thinking
      key="k60"
      since={0}
      now={now}
      liveState="subagents"
      liveAgents={4}
      liveAgentNames={["lint", "tests", "docs"]}
      turnTotal
    />,
  ],
  ...WAITS.map(([name, liveWait]): [string, ReactNode] => [
    name,
    <Thinking key={name} since={0} now={now} phaseAt={0} heardAt={20_000} heardKey="k" liveWait={liveWait} turnTotal />,
  ]),
  ["Compacting", <Thinking key="k73" since={0} now={now} liveState="compacting" doingAt={50_000} turnTotal />],
  ["Retrying", <Thinking key="k74" since={0} now={now} retry={{ attempt: 3, maxRetries: 10, errorStatus: 503 }} />],
  ["Needs you", wait("permission", <Thinking since={0} now={now} />)],
  ["Trust", wait("trust", <Thinking since={0} now={now} />)],
  ["Secret", wait("secret", <Thinking since={0} now={now} />)],
  ["Activity: step", <ActivityLine key="k78" row={{ ...line, text: "Edit ProductGrid.module.css" }} now={now} />],
  ["Activity: thinking", <ActivityLine key="k79" row={line} now={now} />],
  [
    "Activity: sending",
    <ActivityLine key="k82" row={{ ...line, text: "SendMessage", doingSendTo: "Prioritize visible cmux" }} now={now} />,
  ],
  ["Activity: waiting", wait("permission", <ActivityLine row={line} now={now} />)],
];

function Fixture({ surface = "plain" }: Props) {
  const rows = (
    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      {STATUSES.map(([name, node]) => (
        <div key={name} style={{ display: "flex", alignItems: "center", gap: 12, position: "relative" }}>
          <span style={{ flex: "none", width: 128, fontSize: "var(--text-caption)", opacity: 0.6 }}>{name}</span>
          <div style={{ position: "relative", flex: "1 1 auto", minWidth: 0 }}>{node}</div>
        </div>
      ))}
    </div>
  );
  return (
    <div style={{ padding: "16px 24px" }}>
      {surface === "glass" ? (
        <div className="ui-card ui-glass" style={{ padding: 16 }}>
          {rows}
        </div>
      ) : (
        rows
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.live-spot-shimmer",
  title: "Live spot: every status under one shimmer",
  area: "Agent pane",
  pane: true,
  height: 1040,
  widths: { narrow: 420, normal: 640 },
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("../../../ui/glass/glass.css")]),
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/ActivityLine.tsx",
    "agent-session/acpmux/conversation/LiveShimmer.tsx",
  ],
  keywords: ["thinking", "shimmer", "glimmer", "waiting", "sending", "status", "live", "ST-03", "ST-04"],
  options: [
    {
      id: "surface",
      label: "Surface",
      kind: "choice",
      choices: [
        { value: "plain", label: "Plain" },
        { value: "glass", label: "Glass" },
      ],
      defaultValue: "plain",
    },
  ],
  variants: {
    plain: { props: { surface: "plain" }, note: "Every status on the transcript (light or dark from the controls)." },
    glass: { props: { surface: "glass" }, note: "Every status on a glass card, as a glass theme draws the pane." },
  },
  load: () => Promise.resolve(Fixture),
});
