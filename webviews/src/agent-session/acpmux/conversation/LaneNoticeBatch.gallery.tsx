// l10n-allow-file: synthetic report and inbox capture fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { LaneNoticeBatch } from "./LaneNoticeBatch";
import { inboxMany, report } from "./laneNotice.gallery-fixtures";
import { batchLaneNotices, flattenInboxRows } from "./laneNoticeBatches";
import { setMessageOpened } from "./incomingOpened";
import { resetTranscriptDisclosure, TranscriptDisclosureProvider } from "./transcriptDisclosure";

type Props = { kind: "reports" | "inbox" | "single"; expanded: boolean };

function Stage({ kind, expanded }: Props) {
  const session = `gallery-lane-notice-${kind}-${expanded}`;
  const [rows] = useState(() => {
    resetTranscriptDisclosure(session);
    const source =
      kind === "inbox"
        ? [inboxMany(session)]
        : kind === "single"
          ? [report(4, session)]
          : [0, 1, 2, 3, 4].map((index) => report(index, session));
    const members = kind === "inbox" ? flattenInboxRows(source) : source;
    const grouped = batchLaneNotices(members);
    for (const row of [...members, ...grouped]) setMessageOpened(session, row.id, false);
    return grouped;
  });
  const render = (row: AcpmuxRow) =>
    row.laneNoticeBatch ? (
      <LaneNoticeBatch key={row.id} row={row} renderMessage={render} />
    ) : row.incoming?.kind === "message" ? (
      <IncomingMessageLine key={row.id} id={row.id} message={row.incoming.message} onOpen={() => {}} />
    ) : null;
  return (
    <PromptMarksSession.Provider value={session}>
      <TranscriptDisclosureProvider sessionId={session}>
        <div className="acpmux-shell" style={{ padding: 16, maxWidth: 800, alignItems: "flex-start" }}>
          <div data-lane-notice-content="" style={{ width: "100%", minWidth: 0 }}>
            {rows.map(render)}
          </div>
        </div>
      </TranscriptDisclosureProvider>
    </PromptMarksSession.Provider>
  );
}

const open: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__toggle, .cv-disclosure__toggle"));
  const batch = ctx.document.querySelector<HTMLButtonElement>(".cv-lane-batch__toggle");
  if (batch) {
    batch.click();
    await ctx.waitFor(() => ctx.document.querySelector(".cv-received"));
  }
  const lines = [...ctx.document.querySelectorAll<HTMLElement>(".cv-received")];
  for (const line of lines) {
    if (lines.length === 1 || line.textContent?.includes("BLOCK") || !line.classList.contains("cv-lane-notice"))
      line.querySelector<HTMLButtonElement>(".cv-disclosure__toggle")?.click();
  }
  await ctx.waitFor(
    () => batch?.getAttribute("aria-expanded") === "true" || ctx.document.querySelector(".cv-received__text"),
  );
  await ctx.waitFor(() =>
    ctx.document
      .getAnimations()
      .every((animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity),
  );
};
const closed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-lane-batch__toggle, .cv-disclosure__toggle"));
};
const variant = (kind: Props["kind"], expanded: boolean, note: string) => ({
  props: { kind, expanded },
  note,
  play: expanded ? open : closed,
});

export default componentEntry<Props>({
  id: "agent-pane.lane-notices",
  title: "Lane reports and inbox notices",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 390, normal: 680, wide: 860 },
  covers: [
    "agent-session/acpmux/conversation/LaneNoticeBatch.tsx",
    "agent-session/acpmux/conversation/laneNoticeBatches.ts",
    "agent-session/acpmux/conversation/laneReport.ts",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    "reports-collapsed": variant("reports", false, "Five ended reviews occupy one line: four SHIP and one BLOCK."),
    "reports-expanded": variant(
      "reports",
      true,
      "The five reports keep their names and disclosures; the BLOCK shows both full findings.",
    ),
    "inbox-collapsed": variant("inbox", false, "Thirteen inbox deliveries render as one flat run of sender rows."),
    "inbox-expanded": variant("inbox", true, "Each inbox delivery expands as its own received message row."),
    "single-collapsed": variant(
      "single",
      false,
      "A lone report stays its own one-line disclosure, with its verdict instead of turn bookkeeping.",
    ),
    "single-expanded": variant(
      "single",
      true,
      "The complete P1 and P2 findings, with Session and Commits behind Details.",
    ),
  },
});
