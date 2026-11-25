// l10n-allow-file: gallery fixtures (chat and subagent names, recorded messages), not shipped UI.
// The top of a subagent's view beside a normal chat's, at the same pane width (Leo, 2026-11-22: "i
// notice there's differing layouts among it and normal chats. like the metadata about provenance or
// whatever like subagent of something. we shouldn't have those. we should align things better.").
// Looks compared, each at a half, third and quarter of a 1440 px window:
// - `before`: the "Subagent of <chat> · <task>" pill as it was, a 44 px row pinned over the rows,
//   pushing the first message down (redrawn here from the removed SubagentOfPillRow; not shipped);
// - `shipped`: no pill; the first message sits where the chat's does, and the in-place view keeps a
//   × in the transcript's top end corner (SubagentViewCorner.tsx), over the rows, taking no room;
// - `no-close`: no × at all: Escape and back-navigation close the view (not picked: a person who
//   does not know Escape has no way back, Leo 2026-11-03: "this opened subagent has no close button");
// - `stopped`: the shipped corner on a stopped helper: Resume beside the × (Leo, 2026-11-12).
// Synthetic data.
import type { CSSProperties, ReactNode } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";

type Look = "before" | "shipped" | "no-close" | "stopped";
type Width = "half" | "third" | "quarter";
type Props = { look: Look; width: Width };

/// Each pane's width: that part of a 1440 px window.
const PANE: Record<Width, number> = { half: 720, third: 480, quarter: 360 };
const CHAT = "Release prep";
const TASK = "Review the diff for the release branch";

const AGENT: Subagent = {
  id: "agent-review",
  parent: null,
  name: "Diff review",
  task: TASK,
  kind: "general-purpose",
  state: "cancelled",
  stopReason: "user",
  resumable: true,
  startedAt: minutesAgo(30),
  endedAt: minutesAgo(12),
  prompt: TASK,
};

const rows = (prefix: string, prompt: string, reply: string): AcpmuxRow[] => [
  { id: `${prefix}-prompt`, version: 1, at: minutesAgo(30), kind: "user", text: prompt },
  { id: `${prefix}-reply`, version: 1, at: minutesAgo(29), kind: "assistant", text: reply },
];
const CHAT_ROWS = rows(
  "chat",
  "Get the release branch ready to cut tonight.",
  "I checked the changelog and the version bump; both are in. Next I will read the diff against main.",
);
const AGENT_ROWS = rows(
  "agent",
  TASK,
  "Forty-one files changed. Two need a look: the migration drops a column the importer still reads.",
);

/// The removed pill, as it drew: centered, in a 44 px row over the first message.
function OldPill() {
  const pill: CSSProperties = {
    display: "inline-flex",
    alignItems: "center",
    gap: 6,
    maxWidth: "calc(100% - 32px)",
    padding: "4px 6px 4px 12px",
    borderRadius: 999,
    background: "var(--cv-surface-raised, #8882)",
    color: "var(--agent-muted)",
    fontSize: "var(--text-caption)",
    whiteSpace: "nowrap",
  };
  return (
    <div data-old-pill style={{ height: 44, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <span style={pill}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>
          Subagent of <b style={{ color: "var(--agent-text)" }}>{CHAT}</b> · {TASK}
        </span>
        <span aria-hidden="true" style={{ padding: "0 4px" }}>
          ×
        </span>
      </span>
    </div>
  );
}

const NOTES: Record<Look, string> = {
  before: "Before: the pill's 44 px row pushes the subagent's first message below the chat's.",
  shipped: "Shipped: no pill; both first messages on one line, a × alone in the top end corner.",
  "no-close": "Not picked: no × at all; Escape or back-navigation close it, and nothing says so.",
  stopped: "Shipped, on a stopped helper: Resume beside the ×, still over no row's room.",
};

/// The first message's top in each pane: equal unless the old pill draws.
const firstTop = (ctx: PlayContext, pane: string) =>
  ctx.document.querySelector(`[data-pane="${pane}"] .acpmux-row[data-row-id$="-prompt"]`)?.getBoundingClientRect().top;

function variant(look: Look, width: Width): ComponentVariant<Props> {
  return {
    note: `${NOTES[look]} Each pane ${PANE[width]} px, a ${width} of a 1440 px window.`,
    props: { look, width },
    play: async (ctx) => {
      await ctx.waitFor(() => firstTop(ctx, "chat") !== undefined && firstTop(ctx, "subagent") !== undefined);
      const text = ctx.document.querySelector('[data-pane="subagent"] .acpmux-scroll')?.textContent ?? "";
      if (text.includes("Subagent of")) throw new Error("the subagent's transcript names the chat it came from");
      if (look === "before") return;
      const drop = Math.abs((firstTop(ctx, "chat") ?? 0) - (firstTop(ctx, "subagent") ?? 0));
      if (drop > 1) throw new Error(`the subagent's first message sits ${drop} px off the chat's`);
      const close = ctx.document.querySelector(".cv-subagent-corner__close");
      if ((look === "no-close") !== !close) throw new Error(`the × is ${close ? "drawn" : "missing"} in ${look}`);
      if (look === "stopped" && !ctx.document.querySelector(".cv-subagent-corner .cv-subagent-resume"))
        throw new Error("a stopped helper's corner has no Resume");
    },
  };
}

export default componentEntry<Props>({
  id: "agent-pane.subagent-view-top",
  title: "A subagent's view top beside a chat's",
  area: "Agent pane",
  height: 300,
  widths: { narrow: 760, normal: 1000, wide: 1480 },
  covers: [
    "agent-session/acpmux/subagents/SubagentViewCorner.tsx#SubagentViewCorner",
    "agent-session/acpmux/subagents/subagentRows.ts#childView",
  ],
  keywords: ["subagent", "provenance", "subagent of", "layout", "close", "resume"],
  load: async () => {
    const { VirtualTranscript } = await import("../App");
    const { SubagentViewCorner } = await import("./SubagentViewCorner");
    const { SubagentNavContext } = await import("./subagentGroupModel");
    const { TurnActionsContext } = await import("../conversation/turnActions");
    const { RESUME_CAPABILITY } = await import("./resumeState");
    const actions = {
      retryCapabilities: new Set([RESUME_CAPABILITY]),
      resumeAgent: () => new Promise<undefined>(() => {}),
    };
    const pane = (label: string, children: ReactNode, width: number) => (
      <section
        data-pane={label}
        style={{
          width,
          flex: "none",
          display: "flex",
          flexDirection: "column",
          minHeight: 0,
          borderInlineEnd: "1px solid var(--agent-border, #8884)",
        }}
      >
        <div className="acpmux-main" style={{ height: 260, display: "flex", flexDirection: "column" }}>
          {children}
        </div>
      </section>
    );
    return function GallerySubagentViewTop({ look, width }: Props) {
      const px = PANE[width];
      const corner =
        look === "before" ? undefined : (
          <SubagentViewCorner
            view={AGENT.id}
            agent={look === "stopped" ? AGENT : undefined}
            close={look !== "no-close"}
          />
        );
      return (
        <SubagentNavContext.Provider value={() => {}}>
          <TurnActionsContext.Provider value={actions}>
            <div className="acpmux-shell" style={{ display: "flex" }}>
              {pane(
                "chat",
                <div style={{ flex: 1, minHeight: 0, position: "relative" }}>
                  <VirtualTranscript
                    rows={CHAT_ROWS}
                    sessionId="gallery-chat"
                    expanded={new Set()}
                    onToggleActivity={() => {}}
                  />
                </div>,
                px,
              )}
              {pane(
                "subagent",
                <>
                  {look === "before" && <OldPill />}
                  <div style={{ flex: 1, minHeight: 0, position: "relative" }}>
                    <VirtualTranscript
                      rows={AGENT_ROWS}
                      sessionId="gallery-subagent"
                      expanded={new Set()}
                      onToggleActivity={() => {}}
                      corner={corner}
                    />
                  </div>
                </>,
                px,
              )}
            </div>
          </TurnActionsContext.Provider>
        </SubagentNavContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./subagents.css")]),
  variants: Object.fromEntries(
    (["before", "shipped", "no-close", "stopped"] as const).flatMap((look) =>
      (["half", "third", "quarter"] as const).map((width) => [`${look}-${width}`, variant(look, width)]),
    ),
  ),
});
