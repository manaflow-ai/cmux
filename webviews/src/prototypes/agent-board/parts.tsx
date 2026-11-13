// l10n-allow-file: isolated gallery prototype, not shipped UI.
import { Dialog, DialogTitle } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import {
  axesLabel,
  isStale,
  type Board,
  type EvidenceRecord,
  type PermutationRecord,
  type PermutationStatus,
} from "./ledger";

export const STATUS_LABEL: Record<PermutationStatus, string> = {
  verified: "Verified",
  unverified: "Unverified",
  broken: "Broken",
};

const TYPE_LABEL: Record<EvidenceRecord["type"], string> = {
  screenshot: "Screenshot",
  video: "Video",
  test: "Test",
  build: "Build",
  log: "Log",
  link: "Link",
};

const TYPE_GLYPH: Record<EvidenceRecord["type"], string> = {
  screenshot: "▣",
  video: "▶",
  test: "✓",
  build: "⬢",
  log: "≡",
  link: "↗",
};

export function StatusMark({ status }: { status: PermutationStatus | "building" | "done" | "dropped" }) {
  const tone =
    status === "verified" || status === "done"
      ? "ok"
      : status === "broken"
        ? "bad"
        : status === "dropped"
          ? "off"
          : "wait";
  return (
    <span className={`ab-status ab-status-${tone}`}>
      <span className="ab-sr">{status}</span>
    </span>
  );
}

/** A drawn stand-in for a screenshot, tinted by the permutation's theme axis. */
export function Thumb({ permutation, size = "md" }: { permutation?: PermutationRecord; size?: "sm" | "md" | "lg" }) {
  const theme = permutation?.axes.theme?.toLowerCase();
  const phone = permutation?.axes.platform === "iPhone";
  const state = permutation?.axes.state?.toLowerCase() ?? "";
  const kind = !permutation
    ? "empty"
    : permutation.status === "unverified"
      ? "missing"
      : theme === "dark"
        ? "dark"
        : "light";
  return (
    <span className={`ab-thumb ab-thumb-${kind} ab-thumb-${size}${phone ? " ab-thumb-phone" : ""}`} aria-hidden="true">
      {kind !== "missing" && kind !== "empty" && (
        <>
          <span className="ab-thumb-bar" />
          <span className="ab-thumb-line" />
          <span className={`ab-thumb-line ab-thumb-short${state.includes("empty") ? " ab-thumb-ghost" : ""}`} />
          {permutation?.status === "broken" && <span className="ab-thumb-crack" />}
        </>
      )}
    </span>
  );
}

export function EvidenceChip({
  board,
  evidence,
  onOpen,
}: {
  board: Board;
  evidence: EvidenceRecord;
  onOpen(evidence: EvidenceRecord): void;
}) {
  const stale = isStale(board, evidence);
  return (
    <button
      type="button"
      className={`ab-chip${stale ? " ab-chip-stale" : ""}`}
      onClick={() => onOpen(evidence)}
      title={evidence.caption}
    >
      <span aria-hidden="true">{TYPE_GLYPH[evidence.type]}</span>
      {TYPE_LABEL[evidence.type]}
      {evidence.sha && <code>{evidence.sha.slice(0, 7)}</code>}
      {stale && <span className="ab-stale">stale</span>}
    </button>
  );
}

export function evidenceOf(board: Board, permutation: PermutationRecord): EvidenceRecord[] {
  return (permutation.evidence ?? []).flatMap((id) => {
    const e = board.evidence.get(id);
    return e ? [e] : [];
  });
}

export function EvidenceViewer({
  board,
  evidence,
  onClose,
}: {
  board: Board;
  evidence: EvidenceRecord | null;
  onClose(): void;
}) {
  const proves = evidence
    ? board.permutations.filter((p) => p.evidence?.includes(evidence.id) || evidence.for?.includes(p.id))
    : [];
  return (
    <Dialog open={Boolean(evidence)} onOpenChange={(open) => !open && onClose()} className="ab-dialog ab-viewer">
      {evidence && (
        <>
          <DialogTitle className="ab-dialog-title">{evidence.caption ?? TYPE_LABEL[evidence.type]}</DialogTitle>
          <div className="ab-viewer-media">
            {evidence.type === "screenshot" || evidence.type === "video" ? (
              <Thumb permutation={proves[0]} size="lg" />
            ) : (
              <pre className="ab-viewer-log">{evidence.caption}</pre>
            )}
            {evidence.type === "video" && (
              <span className="ab-play" aria-hidden="true">
                ▶
              </span>
            )}
          </div>
          <dl className="ab-viewer-meta">
            <dt>Type</dt>
            <dd>{TYPE_LABEL[evidence.type]}</dd>
            <dt>Commit</dt>
            <dd>
              <code>{evidence.sha ?? "not recorded"}</code>
              {isStale(board, evidence) && <span className="ab-stale">older than the newest evidence</span>}
            </dd>
            <dt>{evidence.url ? "URL" : "File"}</dt>
            <dd>
              <code className="ab-break">{evidence.url ?? evidence.path}</code>
            </dd>
            <dt>Proves</dt>
            <dd>{proves.length ? proves.map((p) => axesLabel(p.axes)).join(", ") : "nothing linked"}</dd>
          </dl>
          <div className="ab-dialog-actions">
            <DialogButton dialogKey="escape" onClick={onClose}>
              Close
            </DialogButton>
          </div>
        </>
      )}
    </Dialog>
  );
}
