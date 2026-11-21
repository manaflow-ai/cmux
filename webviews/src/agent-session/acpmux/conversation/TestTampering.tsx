import { useContext, useId, useMemo } from "react";
import { TurnActionsContext } from "./turnActions";
import { tamperingForRows, type TamperingEvidence } from "./testTamperingModel";
import { markTamperingRestored, setTestTamperingState, useTestTamperingState } from "./testTamperingStore";
import type { AcpmuxRow } from "../model";
import { useTranscriptReadOnly } from "./readOnly";
import { translate, useT, type StringKey, type Translate } from "../i18n";

export type TestTamperingRestore = (
  finding: TamperingEvidence,
  findingIndex: number,
  all: readonly TamperingEvidence[],
) => Promise<void>;

export type TestTamperingProps = {
  rows: readonly AcpmuxRow[];
  /// The parent session and turn make this state survive transcript virtualization.
  sessionId?: string;
  turnId?: string;
  /// Native restore is intentionally owned by the parent transport. This card remains read-only
  /// when the host cannot provide it (view-only panes and galleries).
  onRestore?: TestTamperingRestore;
};

export function tamperingStateKey({
  rows,
  sessionId,
  turnId,
}: Pick<TestTamperingProps, "rows" | "sessionId" | "turnId">): string {
  const turn = turnId ?? rows.find((row) => row.turnId)?.turnId ?? rows[0]?.turnId ?? rows[0]?.id ?? "unknown";
  return `${sessionId ?? "session"}\u0000${turn}`;
}

export function TestTampering({ rows, sessionId, turnId, onRestore }: TestTamperingProps) {
  const evidence = useMemo(() => tamperingForRows(rows), [rows]);
  const key = tamperingStateKey({ rows, sessionId, turnId });
  const state = useTestTamperingState(key);
  const { answer, restoreTestTampering } = useContext(TurnActionsContext);
  const readOnly = useTranscriptReadOnly();
  const t = useT();
  const bodyId = useId();
  const restorableEvidence = evidence.filter((finding) => finding.new.length > 0);
  const allRestored =
    restorableEvidence.length > 0 &&
    restorableEvidence.every((finding) => state.restored.has(tamperingEvidenceKey(finding)));
  const canRestore = restorableEvidence.length > 0;
  if (evidence.length === 0) return null;

  const restoreAll = async () => {
    const restore = restoreTestTampering ?? onRestore;
    if (!restore || !canRestore || readOnly || state.restore === "pending" || allRestored) return;
    setTestTamperingState(key, { restore: "pending" });
    try {
      await restoreFindings(restore, key, evidence, state.restored);
      setTestTamperingState(key, { restore: "sent" });
    } catch {
      setTestTamperingState(key, { restore: "failure" });
    }
  };

  const askWhy = async () => {
    if (!answer || readOnly || state.askWhy === "pending" || state.askWhy === "sent") return;
    setTestTamperingState(key, { askWhy: "pending" });
    try {
      await answer(askWhyPrompt(evidence, t));
      setTestTamperingState(key, { askWhy: "sent" });
    } catch {
      setTestTamperingState(key, { askWhy: "failure" });
    }
  };

  return (
    <section className="acpmux-tampering" aria-label={t("testTampering.title")}>
      <button
        type="button"
        className="acpmux-tampering-head"
        aria-expanded={state.open}
        aria-controls={bodyId}
        onClick={() => setTestTamperingState(key, { open: !state.open })}
      >
        <span className="acpmux-tampering-mark" aria-hidden="true">
          !
        </span>
        <span className="acpmux-tampering-title">{t("testTampering.title")}</span>
        <span className="acpmux-tampering-chevron" aria-hidden="true">
          {state.open ? "⌃" : "⌄"}
        </span>
      </button>
      {state.open && (
        <div id={bodyId} className="acpmux-tampering-body">
          <ul className="acpmux-tampering-list">
            {evidence.map((finding, index) => (
              <Evidence key={`${finding.path}-${finding.line}-${index}`} finding={finding} t={t} />
            ))}
          </ul>
          <div className="acpmux-tampering-actions">
            <button
              type="button"
              onClick={() => void restoreAll()}
              disabled={
                !(restoreTestTampering ?? onRestore) ||
                !canRestore ||
                readOnly ||
                state.restore === "pending" ||
                allRestored
              }
            >
              {!(restoreTestTampering ?? onRestore) || !canRestore || readOnly
                ? t("testTampering.restoreUnavailable")
                : allRestored
                  ? t("testTampering.restored")
                  : state.restore === "pending"
                    ? t("testTampering.restoring")
                    : state.restore === "failure"
                      ? t("testTampering.retryRestore")
                      : t("testTampering.restore")}
            </button>
            {answer && (
              <button
                type="button"
                onClick={() => void askWhy()}
                disabled={readOnly || state.askWhy === "pending" || state.askWhy === "sent"}
              >
                {state.askWhy === "pending"
                  ? t("testTampering.sending")
                  : state.askWhy === "sent"
                    ? t("testTampering.asked")
                    : t("testTampering.askWhy")}
              </button>
            )}
            {state.restore === "failure" && <output>{t("testTampering.restoreFailure")}</output>}
            {state.askWhy === "failure" && <output>{t("testTampering.askFailure")}</output>}
          </div>
        </div>
      )}
    </section>
  );
}

/// Localize the question shown in the transcript, preserving the evidence blocks verbatim.
export function askWhyPrompt(evidence: readonly TamperingEvidence[], t: Translate = translate): string {
  const details = evidence
    .map(
      (finding) =>
        `- ${finding.line === null ? finding.path : `${finding.path}:${finding.line}`} (${finding.kind})\nOLD:\n${finding.old || "(none)"}\nNEW:\n${finding.new || "(none)"}`,
    )
    .join("\n\n");
  return `${t("testTampering.question")}\n\n${details}`;
}

function tamperingEvidenceKey(finding: TamperingEvidence): string {
  return `${finding.eventSeq ?? "unknown"}:${finding.fileIndex}:${finding.findingIndex}:${finding.kind}:${finding.old}:${finding.new}`;
}

function tamperingReason(t: ReturnType<typeof useT>, kind: string): string {
  const key: StringKey =
    (
      {
        "removed-test": "testTampering.reason.removedTest",
        "introduced-skip": "testTampering.reason.introducedSkip",
        "allowlist-bypass": "testTampering.reason.allowlistBypass",
        "weakened-assertion": "testTampering.reason.weakenedAssertion",
        "removed-assertion": "testTampering.reason.removedAssertion",
      } as Partial<Record<string, StringKey>>
    )[kind] ?? "testTampering.reason.unknown";
  return t(key);
}

async function restoreFindings(
  restore: TestTamperingRestore,
  key: string,
  evidence: readonly TamperingEvidence[],
  restored: ReadonlySet<string>,
): Promise<void> {
  for (const [index, finding] of evidence.entries()) {
    if (finding.new.length === 0) continue;
    const evidenceKey = tamperingEvidenceKey(finding);
    if (restored.has(evidenceKey)) continue;
    await restore(finding, index, evidence);
    markTamperingRestored(key, evidenceKey);
  }
}

function Evidence({ finding, t }: { finding: TamperingEvidence; t: ReturnType<typeof useT> }) {
  return (
    <li>
      <div className="acpmux-tampering-evidence-title">
        <code>{finding.path}</code>
        {finding.line !== null && (
          <span>
            {" "}
            {t("testTampering.line")} {finding.line}
          </span>
        )}
      </div>
      <div className="acpmux-tampering-message">{tamperingReason(t, finding.kind)}</div>
      <pre>
        <del>{finding.old}</del>
        {finding.new && <ins>{finding.new}</ins>}
      </pre>
    </li>
  );
}
