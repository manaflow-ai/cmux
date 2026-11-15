// A reply the agent sent again after a Stop hook (design/revised-reply.md). Leo, 2026-11-14, on the
// same report drawn twice back to back: "why did u send this twice?". acpmux records the second as
// replacing the first (`message_superseded`, reason `stop_hook`, hub/stream.rs), and the pane streams
// it into the first one's row (direct.ts `reviseSupersededMessage`): the row keeps showing the first
// text until the new one has streamed, then swaps it in one frame, so the reply never draws twice and
// nothing below it moves while the agent writes. The look of the mark is an experiment
// (revisedReply.experiment.ts).
import { useId, useState, type ReactNode } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { ChevronRight } from "./icons";
import { Markdown } from "./Markdown";
import { revisedReplyLook } from "./revisedReply.experiment";

/// What a revised reply's row draws now: the first version while the new one streams, else its own.
export function revisedReplyText(row: AcpmuxRow): { text: string; revising: boolean } {
  const revising = Boolean(row.revisedFrom) && row.streaming === true;
  return { text: revising ? row.revisedFrom!.text : (row.text ?? ""), revising };
}

/// The reply `body` of a revised row, with its mark in the experiment's look; any other row's body as
/// it is.
export function RevisedReply({ row, children }: { row: AcpmuxRow; children: ReactNode }) {
  const t = useT();
  const id = useId();
  const [open, setOpen] = useState(false);
  const earlier = row.revisedFrom;
  if (!earlier) return <>{children}</>;
  const look = experimentArm(revisedReplyLook);
  if (look === "silent") return <>{children}</>;
  const revising = row.streaming === true;
  const first = open && !revising && (
    <div className="cv-revised__earlier" id={id} aria-label={t("transcript.revisedEarlier")}>
      <div className="cv-revised__earlier-label">{t("transcript.revisedEarlier")}</div>
      <Markdown>{earlier.text}</Markdown>
    </div>
  );
  if (look === "stack")
    return (
      <div className="cv-revised cv-revised--stack" data-revised={revising ? "revising" : "revised"}>
        <button
          type="button"
          className="cv-revised__toggle"
          aria-expanded={open}
          aria-controls={id}
          disabled={revising}
          title={t("transcript.revisedHint")}
          onClick={() => setOpen((was) => !was)}
        >
          <ChevronRight size={14} className={`cv-revised__chevron cv-rotor${open ? " is-open" : ""}`} />
          {revising ? t("transcript.revising") : t("transcript.revisedEarlier")}
        </button>
        {first}
        {children}
      </div>
    );
  return (
    <div className="cv-revised cv-revised--word" data-revised={revising ? "revising" : "revised"}>
      {children}
      <button
        type="button"
        className="cv-revised__toggle"
        aria-expanded={open}
        aria-controls={id}
        disabled={revising}
        title={t("transcript.revisedHint")}
        onClick={() => setOpen((was) => !was)}
      >
        {revising ? t("transcript.revising") : t("transcript.revised")}
      </button>
      {first}
    </div>
  );
}
