// l10n-allow-file: gallery fixtures (subagent names), not shipped UI.
// A finished subagent's line (SubagentDoneLine.tsx) at the widths it meets: "Subagent finished:
// [name] ›   1m 20s". Leo, 2026-11-03, on a row whose chip was cut at about a third of the pane with
// a lone chevron at its far right: "this is pretty bad spacing and formatting" / "i thought we made
// this stuff smaller". The chip takes the room the row has and is cut only at the row's edge; the
// chevron sits right after it; the duration stays at the line's end. Three looks are compared: the
// chip taking the row (the pick), the chip capped at 60% of the line, and the base's 40% cap, which
// left a gap after the chip. Synthetic data.
//
// A finished sub-session whose record names nothing reads its chat's title, never the bare
// "Subagent" (Leo, 2026-11-03, on a capture where a finished subagent row read "Subagent"). The
// chat's reply to a subagent's end sits under its line on the stack's grid, and the next row keeps
// the one row pitch: four looks of that reply are compared, "grid" the pick.
//
// A finished line with a report (Leo, 2026-11-03, on parallel agents in the running tray: "Tray only,
// richer"): the report variants compare how the line offers it (doneReport.experiment.ts), the
// chevron that opens it under the line (the pick), a two-line preview with Show more, and the line
// that only opens the agent's view.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";
import { doneReportLook, type DoneReportLook } from "./doneReport.experiment";

type Look = "fill" | "cap60" | "before";
/// How the chat's reply sits under the line: on the grid (the pick), as a folded note with the run
/// gap around it, set off by a rule, or the base's 4px and 6px margins.
type ReplyLook = "grid" | "note" | "quote" | "before";
/** `pane`: the column's width in CSS px, for the narrow pane. `subsession`: the line is a
 * sub-session's with no task, whose chat is titled. `reply`: the chat's reply to its end, and a
 * following line under it. `report`: the first line's final report. `arm`: the report look a
 * variant pins; unset, the experiment's arm (the compare view). */
type Props = {
  names: string[];
  look?: Look;
  pane?: number;
  failed?: boolean;
  subsession?: boolean;
  reply?: string;
  replyLook?: ReplyLook;
  report?: string;
  arm?: DoneReportLook;
};

const CHILD_ID = "optchat-5e2a91c4b7d0-3f";
const CHILD_TITLE = "Audit the retry banner flicker";
const REPLY = "The reviewer found one race in the banner's timer; I'll fix it next.";

const REPORT = `Found the drift: the settings schema generator reads \`defaults.json\` before the MDM overlay is applied, so three keys ship with stale defaults.

- \`sidebar.compact\` defaults to \`false\` in the docs but \`true\` in the app
- \`terminal.bell\` is missing from the MDM profile export
- the golden files were regenerated from the stale read

Fixed the read order in \`gen-schema.ts\`, regenerated the golden files and the docs page, and added a test that compares the generator's output with the app's defaults. All 214 settings tests pass.`;

const openReport: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-subagent-done__disclose" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-done__report") !== null);
};

const LONG =
  "Fix defaults-snapshot drift in the settings schema generator, its golden files, the docs page, the MDM profile export and every test that reads them";
const ERROR = "503: no non-exhausted claude accounts available after four retries on the capacity route, giving up";
const SHORT = "Explore";

const done = (
  name: string,
  index: number,
  failed = false,
  subsession = false,
  reply?: string,
  report?: string,
): AcpmuxRow => {
  const agent: Subagent = {
    id: subsession ? `${CHILD_ID}/start-${index}` : `agent-done-${index}`,
    parent: null,
    name: subsession ? `${CHILD_ID}/start-${index}` : name,
    ...(subsession ? { child: CHILD_ID } : { task: name }),
    ...(reply && { reaction: { turn: `turn-${index}`, weight: "result" as const, text: reply } }),
    ...(!subsession && { kind: "general-purpose", prompt: name }),
    state: failed ? "failed" : "completed",
    ...(failed && { error: ERROR }),
    startedAt: minutesAgo(12),
    endedAt: minutesAgo(10.6),
    ...(report && !failed && { result: report }),
  };
  return {
    id: `done-${index}`,
    version: 1,
    kind: "subagentDone" /* subagentRows.ts SUBAGENT_DONE */,
    at: agent.endedAt!,
    subagents: [agent],
  };
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-done",
  title: "Subagent finished line",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-subagent-done-gallery]" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx#SubagentDoneLine",
    "agent-session/acpmux/conversation/ReactionMark.tsx#ReactionReply",
    "agent-session/acpmux/subagents/doneReport.experiment.ts",
  ],
  experiment: {
    definition: doneReportLook,
    // Only the disclosure arm has the chevron to click; the other arms show their resting state.
    script: [
      {
        name: "Open the report",
        run: async (ctx) => {
          if (ctx.document.querySelector(".cv-subagent-done__disclose"))
            await ctx.click({ selector: ".cv-subagent-done__disclose" });
        },
      },
    ],
  },
  load: async () => {
    const { SubagentDoneLine, DoneReportLookContext } = await import("./SubagentDoneLine");
    const { SubagentNavContext } = await import("./SubagentGroup");
    const { SubsessionContext, SubsessionStore } = await import("./subsessions");
    // The sub-session's own chat, titled, as the session list has it.
    const store = new SubsessionStore();
    store.set([
      {
        sessionId: CHILD_ID,
        name: CHILD_ID,
        title: CHILD_TITLE,
        displayTitle: CHILD_TITLE,
        startedBy: "gallery-parent",
        status: "idle",
        lane: "done",
        harness: "claude",
      } as unknown as import("../sessionList").AcpmuxSessionEntry,
    ]);
    const subsessions = { store, open: () => undefined };
    return function GallerySubagentDone({
      names,
      look = "fill",
      pane,
      failed,
      subsession,
      reply,
      replyLook,
      report,
      arm,
    }: Props) {
      return (
        <SubsessionContext.Provider value={subsessions}>
          <SubagentNavContext.Provider value={() => undefined}>
            <DoneReportLookContext.Provider value={arm}>
              <main
                className="acpmux-shell subagent-done-gallery"
                data-subagent-done-gallery
                data-look={look}
                data-reply-look={replyLook}
                style={{ padding: "16px", flexDirection: "column", gap: "0", ...(pane ? { width: `${pane}px` } : {}) }}
              >
                {names.map((name, index) => (
                  <section key={index} className="acpmux-row">
                    <SubagentDoneLine
                      row={done(
                        name,
                        index,
                        failed,
                        subsession,
                        index === 0 ? reply : undefined,
                        index === 0 ? report : undefined,
                      )}
                    />
                  </section>
                ))}
              </main>
            </DoneReportLookContext.Provider>
          </SubagentNavContext.Provider>
        </SubsessionContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./subagents.css"),
      import("./SubagentDoneLine.gallery.css"),
    ]),
  variants: {
    "long-title": {
      note: "The pick, Leo's row: a long name takes the row and is cut with an ellipsis at its edge; the chevron right after the chip, the duration at the line's end.",
      props: { names: [LONG] },
    },
    "short-title": {
      note: "A short name: the chip as wide as its words, the chevron right after it.",
      props: { names: [SHORT, "Push relay"] },
    },
    narrow: {
      note: "A 320px pane: the chip is cut first; the words before it, the chevron and the duration stay.",
      props: { names: [LONG, SHORT], pane: 320 },
    },
    "failed-long-error": {
      note: "A failure with a long error, on the failed-line grid: the reason is cut first, the title keeps its words.",
      props: { names: ["Push relay for GCP lane bundles"], failed: true },
    },
    "cap-60": {
      note: "Version B: the chip capped at 60% of the line. Leaves room on a wide pane, cuts names that would fit.",
      props: { names: [LONG, SHORT], look: "cap60" },
    },
    before: {
      note: "Before: the base's 40% cap, a cut name and an empty gap before the chevron, Leo's capture.",
      props: { names: [LONG, SHORT], look: "before" },
    },
    "subsession-titled": {
      note: 'A finished sub-session whose record names nothing: the line reads its chat\'s title, never the bare "Subagent".',
      props: { names: ["", ""], subsession: true },
    },
    "reply-grid": {
      note: "The pick: the chat's reply to the end on the stack's grid, 20px lines at the text column with no margin of its own; the next line keeps the row pitch.",
      props: { names: [SHORT, "Push relay"], reply: REPLY, replyLook: "grid" },
    },
    "reply-note": {
      note: "Version B: the reply as a folded note, the run gap above and below it.",
      props: { names: [SHORT, "Push relay"], reply: REPLY, replyLook: "note" },
    },
    "reply-quote": {
      note: "Version C: the reply set off by a 2px rule at the text column.",
      props: { names: [SHORT, "Push relay"], reply: REPLY, replyLook: "quote" },
    },
    "reply-before": {
      note: "Before (cmux#33283): 4px over and 6px under the reply, which the row's estimate never counted.",
      props: { names: [SHORT, "Push relay"], reply: REPLY, replyLook: "before" },
    },
    "report-collapsed": {
      note: "A finished agent with a multi-paragraph report, collapsed: the chevron right after the words opens it; the line opens the agent's view.",
      height: 120,
      props: { names: ["Fix defaults-snapshot drift"], report: REPORT, arm: "disclosure" },
    },
    "report-open": {
      note: "The same line, its report opened under it in the transcript's Markdown, capped at 240px and scrolling past it.",
      height: 360,
      props: { names: ["Fix defaults-snapshot drift"], report: REPORT, arm: "disclosure" },
      play: openReport,
    },
    "arm-disclosure": {
      note: "Arm disclosure (the pick): a chevron after the words opens the report; a line with no report keeps its plain mark.",
      height: 140,
      props: { names: ["Fix defaults-snapshot drift", SHORT], report: REPORT, arm: "disclosure" },
    },
    "arm-preview": {
      note: "Arm preview: the report's first two lines always under the line, with Show more.",
      height: 220,
      props: { names: ["Fix defaults-snapshot drift", SHORT], report: REPORT, arm: "preview" },
    },
    "arm-view": {
      note: "Arm view (before): the line only opens the agent's view; the report is there.",
      height: 120,
      props: { names: ["Fix defaults-snapshot drift", SHORT], report: REPORT, arm: "view" },
    },
  },
});
