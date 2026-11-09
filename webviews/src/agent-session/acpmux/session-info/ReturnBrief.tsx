// l10n-allow-file: gallery prototype, not shipped: only ReturnBrief.gallery.tsx imports it (HQ #6236 brief 17).
// Read-only gallery prototype for HQ #6236 brief 17. Receipts come from owner adapters supplied by
// the host; this component has no token, filesystem, network, run, approval or write authority.
import type { ReactNode } from "react";
import { returnBrief, type EvidenceLevel, type ReturnBriefInput, type ReviewItem } from "./returnBriefModel";
import "./returnBrief.css";

export type ReturnBriefProps = {
  input: ReturnBriefInput;
  onReviewChanges?: () => void;
  /** The production host would reauthorize + re-fetch the exact revision before opening it. */
  onOpenArtifact?: (id: string, revision: string, path: string) => void;
};

const levelName: Record<EvidenceLevel, string> = {
  observed: "Observed",
  verified: "Owner verified",
  unverified: "Unverified",
  stale: "Changed or stale",
  failed: "Failed",
  unknown: "Outcome unknown",
  inaccessible: "Access unavailable",
  expired: "Expired",
};

function EvidenceRow({ item, action }: { item: ReviewItem; action?: () => void }) {
  const heading = (
    <>
      <span className="acpmux-return-brief__item-title">{item.label}</span>
      <span className="acpmux-return-brief__level" data-level={item.level}>
        {levelName[item.level]}
      </span>
    </>
  );
  let control: ReactNode;
  if (action) {
    control = (
      <button type="button" className="acpmux-return-brief__go" onClick={action}>
        Review
      </button>
    );
  } else if (item.href) {
    control = (
      <a className="acpmux-return-brief__go" href={item.href} target="_blank" rel="noopener noreferrer">
        Open
      </a>
    );
  }
  return (
    <li className="acpmux-return-brief__item" data-evidence={item.level}>
      <div className="acpmux-return-brief__row-head">{heading}</div>
      <div className="acpmux-return-brief__row-body">
        <span className="acpmux-return-brief__detail">{item.detail}</span>
        {control}
      </div>
    </li>
  );
}

export function ReturnBrief({ input, onReviewChanges, onOpenArtifact }: ReturnBriefProps) {
  const report = returnBrief(input);
  const artifact = input.artifact;
  return (
    <section className="acpmux-return-brief" aria-label="Return brief">
      <div className="acpmux-return-brief__heading">
        <h2>Return brief</h2>
        <p>Review what the chat produced, then open the original evidence.</p>
      </div>
      <div className="acpmux-return-brief__source">
        <span>Source revision</span>
        <code title={input.commit}>{report.source}</code>
        <span>
          Session {input.sessionId} · turn {input.turnId}
        </span>
      </div>
      <ul className="acpmux-return-brief__items">
        {report.items.map((item) => (
          <EvidenceRow
            key={item.id}
            item={item}
            action={
              item.action === "changes"
                ? onReviewChanges
                : item.action === "artifact" && artifact && onOpenArtifact
                  ? () => onOpenArtifact(artifact.id, artifact.revision, artifact.path)
                  : undefined
            }
          />
        ))}
      </ul>
      <section className="acpmux-return-brief__risks" aria-label="Reported residual risks">
        <h3>Residual risks</h3>
        {report.risks.length ? (
          <ul>
            {report.risks.map((risk, index) => (
              <li key={index}>{risk}</li>
            ))}
          </ul>
        ) : (
          <p>Risks unreported. Inspect the original task and owner logs.</p>
        )}
        <p className="acpmux-return-brief__disclaimer">
          Risk notes are reported claims. Evidence levels come from the identified owners.
        </p>
      </section>
    </section>
  );
}
