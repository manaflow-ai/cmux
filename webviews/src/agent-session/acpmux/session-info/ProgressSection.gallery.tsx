// l10n-allow-file: gallery fixtures (sample plan steps), not shipped UI.
// Session Info's Progress (ProgressSection.tsx): the agent's plan, live (the header's appearance
// switch shows light and dark). No plan,
// mid-plan, done, a turn that ended with a step left in progress, and `live`, whose play ticks the
// plan's steps the way an agent's TodoWrite updates do and checks each one shows in place.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxPlanEntry } from "../model";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";
import { DEFAULT_SECTIONS } from "./sessionInfoState";

type Status = AcpmuxPlanEntry["status"];
type Props = { statuses?: readonly Status[]; ended?: boolean; live?: boolean };

const STEPS = [
  "Read the Session Info sections and the plan the transcript draws",
  "Add a Progress section on the panel's grid",
  "Show each step's state: pending, in progress, done",
  "Gallery variants for no plan, mid-plan and done",
  "Run the webview tests on the fleet",
];
const MID: Status[] = ["completed", "completed", "in_progress", "pending", "pending"];
const DONE: Status[] = STEPS.map(() => "completed");
/// The `live` variant's plan after each tick: one step done, the next in progress.
const tick = (done: number): Status[] =>
  STEPS.map((_, index) => (index < done ? "completed" : index === done ? "in_progress" : "pending"));

function GalleryProgress({ statuses, ended = false, live = false }: Props) {
  const [done, setDone] = useState(0);
  const now = live ? tick(done) : statuses;
  const plan = now && { entries: STEPS.map((content, index) => ({ content, status: now[index]! })), ended };
  return (
    <div
      className="acpmux-shell"
      style={{ position: "relative", display: "flex", justifyContent: "flex-end", height: "100%" }}
    >
      {live && (
        <button
          type="button"
          data-gallery-tick
          // Left of the panel, in the room the narrowest panel (260px) leaves, so the panel never covers it.
          style={{ position: "absolute", left: 8, top: 8 }}
          onClick={() => setDone((at) => Math.min(STEPS.length, at + 1))}
        >
          Tick
        </button>
      )}
      <SessionInfoPanel width={260} placement="overlay">
        <SessionInfo machineName="Studio" plan={plan} sections={DEFAULT_SECTIONS} more />
      </SessionInfoPanel>
    </div>
  );
}

const steps = (doc: Document) => [
  ...doc.querySelectorAll<HTMLElement>('[data-section="progress"] .acpmux-session-info-progress__step'),
];
const states = (doc: Document) => steps(doc).map((step) => step.dataset.status);
const meta = (doc: Document) =>
  doc.querySelector('[data-section="progress"] .acpmux-session-info-section__value')?.textContent ?? "";

/// The steps draw with their states, the count in the head, and each mark centred on its step's first
/// line in the icon column, the words on the panel's text column.
const drawsPlan =
  (expected: readonly Status[], count: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => steps(ctx.document).length === expected.length);
    if (states(ctx.document).join() !== expected.join()) throw new Error(`states: ${states(ctx.document).join()}`);
    if (meta(ctx.document) !== count) throw new Error(`head reads "${meta(ctx.document)}", not "${count}"`);
    const title = ctx.find({ selector: '[data-section="progress"] .acpmux-session-info-section__title' });
    for (const step of steps(ctx.document)) {
      const text = step.querySelector(".acpmux-session-info-progress__text")!.getBoundingClientRect();
      if (Math.abs(text.left - title.getBoundingClientRect().left) > 0.5)
        throw new Error("a step's words are off the section's text column");
      const mark = step.querySelector(".acpmux-session-info-progress__mark")!.getBoundingClientRect();
      if (Math.abs(mark.top + mark.height / 2 - (text.top + 8)) > 1)
        throw new Error("a step's mark is not centred on its first line");
    }
  };

export default componentEntry<Props>({
  id: "agent-pane.session-info-progress",
  title: "Session Info Progress",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 360, normal: 420 },
  covers: [
    "agent-session/acpmux/session-info/ProgressSection.tsx",
    "agent-session/acpmux/session-info/SessionInfo.tsx",
    "agent-session/acpmux/session-info/sessionInfo.css",
  ],
  load: async () => GalleryProgress,
  variants: {
    "no-plan": {
      note: "A chat whose agent wrote no plan: no Progress section, nothing in its place.",
      props: {},
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info__body"));
        if (ctx.document.querySelector('[data-section="progress"]')) throw new Error("Progress drew with no plan");
      },
    },
    "mid-plan": {
      note: "Mid-plan, light: two steps done (muted, a filled check), one in progress (the shared spinner), two waiting (a dashed ring). The head reads 2 of 5 on Context's meter.",
      props: { statuses: MID },
      play: drawsPlan(MID, "2 of 5"),
    },
    done: {
      note: "Every step done: all muted with checks, the meter full.",
      props: { statuses: DONE },
      play: drawsPlan(DONE, "5 of 5"),
    },
    ended: {
      note: "The turn ended with a step left in progress: a plain ring, never a spinner frozen mid-turn.",
      props: { statuses: MID, ended: true },
      play: async (ctx) => {
        await drawsPlan(MID, "2 of 5")(ctx);
        if (ctx.document.querySelector('[data-section="progress"] .cv-spinner')) throw new Error("an ended plan spins");
      },
    },
    live: {
      note: "Live: each tick is a plan update (a step done, the next in progress), and the section follows in place.",
      props: { live: true },
      play: async (ctx) => {
        await drawsPlan(tick(0), "0 of 5")(ctx);
        for (let done = 1; done <= STEPS.length; done += 1) {
          await ctx.click({ selector: "[data-gallery-tick]" });
          await ctx.waitFor(() => states(ctx.document).join() === tick(done).join());
        }
        if (meta(ctx.document) !== "5 of 5") throw new Error(`head reads "${meta(ctx.document)}"`);
      },
    },
  },
});
