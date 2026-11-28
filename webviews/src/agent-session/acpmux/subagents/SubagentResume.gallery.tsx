// l10n-allow-file: gallery fixtures (subagent names and tasks), not shipped UI.
// Resume on a stopped helper wherever its row or tab shows (ResumeControl.tsx; Leo, 2026-11-12: "A
// Resume button in cmux on a stopped helper's row and tab. It starts a fresh session from that
// helper's record and original instructions, and carries on from there."): the tray's finished
// line, Session Info's Subagents and the helper's own tab, in its transcript's top end corner
// (SubagentViewCorner.tsx), which draws no line about where the helper came from (Leo, 2026-11-22). Each at rest,
// busy once clicked (acpmux has it), and refused with the note it leaves. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { RetryNote } from "./retryState";
import type { Subagent } from "./subagentFold";

type Surface = "tray" | "sessionInfo" | "tab";
/** `refused`: acpmux answers with this note; `busy`: it never answers (the request is under way). */
type Props = { surface: Surface; answer?: "busy" | RetryNote };

const STOPPED: Subagent = {
  id: "agent-relay",
  parent: null,
  name: "Push relay",
  task: "Push relay for GCP lane bundles",
  kind: "general-purpose",
  state: "cancelled",
  stopReason: "user",
  resumable: true,
  startedAt: minutesAgo(40),
  endedAt: minutesAgo(16),
  prompt: "Push relay for GCP lane bundles",
};
const DONE: Subagent = {
  ...STOPPED,
  id: "agent-docs",
  name: "Docs pass",
  task: "Tighten the running tray spec",
  state: "completed",
  resumable: false,
  stopReason: undefined,
  endedAt: minutesAgo(30),
};
const NO_WAITING = new Set<string>();

/** The tray starts folded and Session Info folds its ended rows: open them, then press Resume. */
const press =
  (surface: Surface): Play =>
  async (ctx) => {
    if (surface === "tray") await ctx.click({ selector: ".acpmux-running-tray__head" });
    if (surface === "sessionInfo") await ctx.click({ selector: ".acpmux-session-info-subagents__ended" });
    if (surface !== "tab") await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-resume"));
    await ctx.click({ selector: ".cv-subagent-resume" });
    await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-resume:disabled, .cv-subagent-resume__note"));
  };
const openTray: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-resume"));
};
const openEnded: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-session-info-subagents__ended" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-resume"));
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-resume",
  title: "Resume a stopped subagent",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 720, wide: 900 },
  covers: [
    "agent-session/acpmux/subagents/ResumeControl.tsx",
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/session-info/SubagentsSection.tsx",
    "agent-session/acpmux/subagents/SubagentViewCorner.tsx#SubagentViewCorner",
  ],
  keywords: ["subagent", "resume", "stopped", "helper"],
  load: async () => {
    const { SubagentTray } = await import("./SubagentTray");
    const { SubagentsSection } = await import("../session-info/SubagentsSection");
    const { SubagentViewCorner } = await import("./SubagentViewCorner");
    const { TurnActionsContext } = await import("../conversation/turnActions");
    const { RESUME_CAPABILITY } = await import("./resumeState");
    const retryCapabilities = new Set([RESUME_CAPABILITY]);
    return function GallerySubagentResume({ surface, answer }: Props) {
      const resume = {
        retryCapabilities,
        resumeAgent: () =>
          answer === "busy" || answer === undefined
            ? new Promise<undefined>(() => {})
            : Promise.resolve<RetryNote | undefined>(answer),
      };
      return (
        <div className="acpmux-shell" style={{ padding: "16px", flexDirection: "column", gap: "4px" }}>
          {surface === "tray" && (
            <SubagentTray
              items={[]}
              finished={[
                { kind: "agent", id: STOPPED.id, agent: STOPPED, depth: 0 },
                { kind: "agent", id: DONE.id, agent: DONE, depth: 0 },
              ]}
              working={false}
              waiting={NO_WAITING}
              onOpen={() => {}}
              resume={resume}
            />
          )}
          {surface === "sessionInfo" && (
            <div className="acpmux-session-info" style={{ width: 320 }}>
              <SubagentsSection agents={[STOPPED, DONE]} waiting={NO_WAITING} onOpen={() => {}} resume={resume} />
            </div>
          )}
          {surface === "tab" && (
            <TurnActionsContext.Provider value={resume}>
              <div className="acpmux-view-corner" data-zone="top-end" style={{ position: "relative" }}>
                <SubagentViewCorner view={STOPPED.id} agent={STOPPED} close={false} />
              </div>
            </TurnActionsContext.Provider>
          )}
        </div>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./subagents.css"),
      import("../session-info/sessionInfo.css"),
    ]),
  variants: {
    "tray-idle": {
      note: "The tray's finished lines: the stopped one offers Resume in Stop's column, the finished one nothing.",
      props: { surface: "tray" },
      play: openTray,
    },
    "tray-busy": {
      note: 'Resume pressed: off while acpmux has it, until the row changes (the run it started links to it). A Resume acpmux refuses as busy (a turn runs) looks the same: it is asked again on its own, never a "try again shortly".',
      props: { surface: "tray", answer: "busy" },
      play: press("tray"),
    },
    "tray-refused": {
      note: "acpmux refused: its note lies where the line's time was, and Resume can be pressed again.",
      props: { surface: "tray", answer: "retry.gone" },
      play: press("tray"),
    },
    "session-info-idle": {
      note: "Session Info's ended rows, opened: Resume after the stopped one's state.",
      props: { surface: "sessionInfo" },
      play: openEnded,
    },
    "session-info-busy": {
      note: "Session Info, Resume pressed: off while acpmux has it.",
      props: { surface: "sessionInfo", answer: "busy" },
      play: press("sessionInfo"),
    },
    "session-info-refused": {
      note: "Session Info, refused: the note before the button.",
      props: { surface: "sessionInfo", answer: "retry.failed" },
      play: press("sessionInfo"),
    },
    "tab-idle": {
      note: "The helper's own tab: Resume in its transcript's top end corner, over no row's room; its tab closes it, so no ×.",
      props: { surface: "tab" },
    },
    "tab-busy": {
      note: "The tab, Resume pressed: off while acpmux has it.",
      props: { surface: "tab", answer: "busy" },
      play: press("tab"),
    },
    "tab-refused": {
      note: "The tab, refused: the note before the button.",
      props: { surface: "tab", answer: "retry.running" },
      play: press("tab"),
    },
  },
});
