// l10n-allow-file: gallery fixtures (sample prompts, commands and subagent names), not shipped UI.
// What waits on the agent's side (agentSide.ts) lists in Session Info's Background tasks, never in
// the composer's stack. Leo, 2026-11-24, of the held bar over the composer: "this, it's not aligned.
// it's also not useful to show this to the user"; of acpmux's queued prompts: "why would a user steer
// or whatever on these? they should be separated out from the user visible steer ui area. maybe not
// even interactable?"
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import { Composer } from "../Composer";
import { useT } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import type { SurgeHold } from "../conversation/surgeHold";
import { agentSideRows } from "./agentSide";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";

type Props = { stage: "composer" | "held" | "queued" | "busy" };

const SURGE =
  "Held during a message surge: 10 message(s) in 8 thread(s) need you. Read them with inbox_read and answer each in its thread.";
const RESUME =
  'Your subagent "Sweep hover rows" (agent id abb9624d75985f07d) failed on a transient upstream error (529). Resume it';
const MINE = "Then check every row that keeps room for a button that only shows on hover, and give them one layout";

const QUEUE: AcpmuxSnapshot["queue"] = [
  { id: "d-surge", prompt: SURGE, system: "surge_digest" },
  {
    id: "r-resume",
    prompt: RESUME,
    system: "subagent_retry",
    retry: { name: "Sweep hover rows", agentId: "abb9624d75985f07d", error: "529" },
  },
  { id: "p-own", prompt: MINE },
];
const HELD: SurgeHold = { held: 35, needYou: 3, seq: 1 };

function snapshot(): AcpmuxSnapshot {
  const base = chat(
    [user("Fix the queue rows' early ellipsis", 4), assistant("Working on the shared row layout now.", 3)],
    { title: "Queue rows", harness: "claude", model: "opus" },
  );
  return { ...base, summary: { ...base.summary!, status: "running" }, queue: QUEUE, surge: HELD };
}

const NoChips = () => null;

function Stage({ stage }: Props) {
  const t = useT();
  if (stage === "composer")
    return (
      <section className="acpmux-shell" style={{ height: "100%" }}>
        <div className="acpmux-main">
          <div className="acpmux-stage" />
          <div className="acpmux-dock">
            <Composer snapshot={snapshot()} chips={NoChips} onSend={() => true} onStop={() => undefined} />
          </div>
        </div>
      </section>
    );
  const rows = agentSideRows(t, HELD, stage === "held" ? [] : QUEUE);
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}>
      <SessionInfoPanel width={300} placement="overlay">
        <SessionInfo
          machineName="Studio"
          processes={
            stage === "busy"
              ? [{ id: "gallery-test", command: "bun test --watch", startedAt: minutesAgo(4), state: "running" }]
              : []
          }
          agentSide={rows}
        />
      </SessionInfoPanel>
    </div>
  );
}

/// The composer holds only the person's own queued prompt: no held bar, no acpmux prompt.
const composerOwnOnly: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-prompt-id="p-own"]'));
  for (const id of ["d-surge", "r-resume"])
    if (ctx.document.querySelector(`[data-prompt-id="${id}"]`)) throw new Error(`${id} draws in the composer`);
  if (ctx.document.querySelector(".acpmux-surge-row, .acpmux-queue-system")) throw new Error("A held bar draws");
};

/// The rows sit inside Background tasks, every one within the section's edges, with no button.
const rowsInPanel =
  (count: number): Play =>
  async (ctx) => {
    const list = '[data-section="agent-side"]';
    await ctx.waitFor(() => ctx.document.querySelector(list));
    const section = ctx.find({ selector: list }).getBoundingClientRect();
    const rows = ctx.document.querySelectorAll<HTMLElement>(`${list} > li`);
    if (rows.length !== count) throw new Error(`${rows.length} rows, expected ${count}`);
    for (const row of rows) {
      const box = row.getBoundingClientRect();
      if (box.left < section.left - 0.5 || box.right > section.right + 0.5) throw new Error("A row leaves the section");
      if (row.querySelector("button")) throw new Error("An agent-side row has a button");
    }
  };

export default componentEntry<Props>({
  id: "agent-pane.session-info-agent-side",
  title: "Held messages and acpmux's prompts in Background tasks",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 320, normal: 760 },
  covers: [
    "agent-session/acpmux/session-info/AgentSideRows.tsx",
    "agent-session/acpmux/session-info/agentSide.ts",
    "agent-session/acpmux/ComposerQueue.tsx#ComposerQueue",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../bottomStack.css"),
      import("../conversation/conversation.css"),
      import("./sessionInfo.css"),
    ]),
  load: async () => Stage,
  variants: {
    composer: {
      props: { stage: "composer" },
      note: "The composer while 35 messages are held, a surge digest and a subagent's resume are queued: only the person's own prompt shows. The held bar and acpmux's prompts are gone from the composer's stack.",
      play: composerOwnOnly,
    },
    held: {
      props: { stage: "held" },
      note: "Session Info's Background tasks with the held surge alone: one plain row, its count at the edge, 3 needing the agent in grey. No button.",
      play: rowsInPanel(1),
    },
    queued: {
      props: { stage: "queued" },
      note: "The held surge, then acpmux's two queued prompts, each one line marked Queued by cmux; the whole prompt is the row's tooltip.",
      play: rowsInPanel(3),
    },
    busy: {
      props: { stage: "busy" },
      note: "The same under a running background command: the person's tasks first, the agent's side at the foot.",
      play: rowsInPanel(3),
    },
  },
});
