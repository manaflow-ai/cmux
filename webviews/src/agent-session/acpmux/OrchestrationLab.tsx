// l10n-allow-file: deterministic sample labels for the read-only orchestration gallery.
import { useRef, useState } from "react";
import { Disclosure } from "../../ui/Disclosure";
import { Popover } from "../../ui/Popover";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { StatusGlyphName } from "../../ui/statusGlyphs.generated";
import { Toolbar, ToolbarButton } from "../../ui/Toolbar";
import { usePopoverTrigger } from "../../ui/popoverTrigger";

type WorkStatus = "working" | "blocked" | "waiting" | "done";
type Decision = "none" | "needs-approval";
type PreviewChoice = "keep-local" | "use-cloud";

type WorkItem = {
  id: string;
  title: string;
  agent: string;
  machine: string;
  status: WorkStatus;
  blocker: string;
  outcome: string;
  decision: Decision;
  decisionQuestion?: string;
  route: string;
  transport: "loopback" | "ssh" | "lease";
  task: string;
  lease: string;
  head: string;
  receiptStatus: "running" | "blocked" | "reviewed";
  state: "submitted" | "running";
  acceptance: "accepted" | "conditional" | "pending";
  proposalKind: "dispatch" | "reconcile" | "wait";
};

const workItems: WorkItem[] = [
  {
    id: "local-queue",
    title: "Review GalleryApp layout",
    agent: "Avery",
    machine: "Mac mini · local",
    status: "working",
    blocker: "No blocker",
    outcome: "Running a bounded visual pass",
    decision: "none",
    route: "loopback · local-supervisor",
    transport: "loopback",
    task: "orch-local-01",
    lease: "09:42 remaining",
    head: "4ce7c9c1…",
    receiptStatus: "running",
    state: "running",
    acceptance: "accepted",
    proposalKind: "dispatch",
  },
  {
    id: "huge-blue",
    title: "Verify Linux cleanup",
    agent: "Mina",
    machine: "Huge Blue · Linux",
    status: "blocked",
    blocker: "Waiting for cleanup verification",
    outcome: "Waiting for cleanup verification",
    decision: "none",
    route: "ssh · enrolled host",
    transport: "ssh",
    task: "orch-huge-blue-07",
    lease: "17:30 remaining",
    head: "ce704bfb…",
    receiptStatus: "blocked",
    state: "submitted",
    acceptance: "conditional",
    proposalKind: "reconcile",
  },
  {
    id: "cloud-fair-share",
    title: "Run gallery checks",
    agent: "Noah",
    machine: "Cloud worker · proposed",
    status: "waiting",
    blocker: "Waiting for your approval",
    outcome: "Waiting for approval to run checks on the proposed cloud worker",
    decision: "needs-approval",
    decisionQuestion: "Move gallery checks to the cloud worker?",
    route: "durable lease · cloud-router",
    transport: "lease",
    task: "orch-cloud-12",
    lease: "Starts on admission",
    head: "a81f6de2…",
    receiptStatus: "reviewed",
    state: "submitted",
    acceptance: "pending",
    proposalKind: "wait",
  },
];

const statusLabels: Record<WorkStatus, string> = {
  working: "Working",
  blocked: "Blocked",
  waiting: "Needs your decision",
  done: "Done",
};

const statusGlyphs: Record<WorkStatus, StatusGlyphName> = {
  working: "working",
  blocked: "error",
  waiting: "waiting",
  done: "done",
};

function ReceiptInspector({ work, onClose }: { work: WorkItem; onClose: () => void }) {
  const receipt = {
    schema_version: 1,
    message_id: "redacted",
    task_id: work.task,
    in_reply_to: "redacted",
    sender: "cmux-chat",
    recipient: "fixture-supervisor",
    transport: work.transport,
    host_id: "fixture-host",
    session_id: "redacted",
    root_id: "gallery-fixture",
    owner: "gallery-fixture",
    kind: "progress",
    authority_ref: "user-request:orchestration-lab-gallery-prototype",
    stage: "working",
    state: work.state,
    status: work.receiptStatus,
    acceptance: work.acceptance,
    repository: "cmux",
    worktree: "agent-chat",
    branch: "fixture",
    base_sha: "1".repeat(64),
    head_sha: "2".repeat(64),
    artifact_sha: "3".repeat(64),
    command: `gallery.fixture --work ${work.id}`,
    assertion_count: 0,
    artifacts: { preview: "fixture-only" },
    evidence: [],
    gap: work.blocker,
    next_action: work.outcome,
  };
  return (
    <div className="orchestration-inspector-content">
      <div className="orchestration-inspector-header">
        <strong>Technical receipt</strong>
        <button type="button" className="orchestration-text-button" onClick={onClose}>
          Close
        </button>
      </div>
      <dl className="orchestration-inspector-facts">
        <div>
          <dt>Task</dt>
          <dd>{work.task}</dd>
        </div>
        <div>
          <dt>Transport</dt>
          <dd>{work.transport}</dd>
        </div>
        <div>
          <dt>Receipt</dt>
          <dd>{work.receiptStatus}</dd>
        </div>
        <div>
          <dt>Acceptance</dt>
          <dd>{work.acceptance}</dd>
        </div>
      </dl>
      <Disclosure label="Show sample receipt JSON">
        <pre aria-label="Sample receipt JSON">{JSON.stringify(receipt, null, 2)}</pre>
      </Disclosure>
      <p className="orchestration-inspector-note">Deterministic fixture data. No command or task ran.</p>
    </div>
  );
}

export function OrchestrationLab({
  initialStrategy = "local-queue",
  initialInspectorOpen = false,
}: {
  /** Kept for the existing local-queue, huge-blue and cloud-fair-share gallery links. */
  initialStrategy?: string;
  initialInspectorOpen?: boolean;
}) {
  const [selectedId, setSelectedId] = useState(
    workItems.some((item) => item.id === initialStrategy) ? initialStrategy : workItems[0].id,
  );
  const [decision, setDecision] = useState<Record<string, PreviewChoice>>({});
  const [inspectorOpen, setInspectorOpen] = useState(initialInspectorOpen);
  const inspectorButton = useRef<HTMLButtonElement | null>(null);
  const selected = workItems.find((item) => item.id === selectedId) ?? workItems[0];
  const trigger = usePopoverTrigger(inspectorOpen, setInspectorOpen);

  const selectWork = (id: string) => {
    setSelectedId(id);
    setInspectorOpen(false);
  };
  const chooseDecision = (value: PreviewChoice) => setDecision((current) => ({ ...current, [selected.id]: value }));
  const chosenDecision = decision[selected.id];
  const decisionText = (value: PreviewChoice) => (value === "keep-local" ? "keep local" : "use cloud");
  const visibleStatus = (item: WorkItem) =>
    item.decision !== "none" && decision[item.id] ? "Preview selected" : statusLabels[item.status];
  const visibleGlyph = (item: WorkItem): StatusGlyphName =>
    item.decision !== "none" && decision[item.id] ? "idle" : statusGlyphs[item.status];
  const visibleStateClass = (item: WorkItem) =>
    item.decision !== "none" && decision[item.id]
      ? "orchestration-state orchestration-state-recorded"
      : `orchestration-state orchestration-state-${item.status}`;
  const visibleRowNote = (item: WorkItem) =>
    item.decision !== "none"
      ? decision[item.id]
        ? `Choice: ${decisionText(decision[item.id])}`
        : ""
      : item.blocker === "No blocker"
        ? ""
        : item.blocker;
  const pendingDecisionItems = workItems.filter((item) => item.decision !== "none" && !decision[item.id]);

  return (
    <main className="orchestration-gallery" data-orchestration-lab>
      <header className="orchestration-gallery-header">
        <h1>Work</h1>
        <span className="orchestration-sample-marker">Sample data · preview only</span>
      </header>
      <Toolbar label="Work summary" className="orchestration-attention">
        <span className="orchestration-attention-count">
          <StatusGlyph name="working" size={12} />
          {workItems.filter((item) => item.status === "working").length} running ·{" "}
          {workItems.filter((item) => item.status === "blocked").length} blocked
        </span>
        {pendingDecisionItems.length > 0 ? (
          <ToolbarButton
            label={`Review decision (${pendingDecisionItems.length})`}
            tooltip={false}
            className="orchestration-decision-jump"
            onPress={() => selectWork(pendingDecisionItems[0].id)}
          >
            <StatusGlyph name="waiting" size={12} />
            <span>Review decision ({pendingDecisionItems.length})</span>
          </ToolbarButton>
        ) : (
          <span className="orchestration-no-decisions">No decisions waiting</span>
        )}
      </Toolbar>

      <div className="orchestration-work-view">
        <section className="orchestration-work-list" aria-label="Work by agent and machine">
          <div className="orchestration-section-heading">
            <h2>Sessions</h2>
          </div>
          <div className="orchestration-work-rows" aria-label="Select work">
            {workItems.map((item) => {
              const isSelected = item.id === selected.id;
              return (
                <button
                  key={item.id}
                  type="button"
                  aria-pressed={isSelected}
                  className={`orchestration-work-row${isSelected ? " is-selected" : ""}`}
                  onClick={() => selectWork(item.id)}
                >
                  <span className="orchestration-work-row-top">
                    <StatusGlyph name={visibleGlyph(item)} size={12} />
                    <strong>{item.title}</strong>
                    <span className={visibleStateClass(item)}>{visibleStatus(item)}</span>
                  </span>
                  <span className="orchestration-work-row-meta">
                    {item.agent} · {item.machine}
                  </span>
                  {visibleRowNote(item) && (
                    <span className={`orchestration-work-row-blocker${item.status === "blocked" ? " is-blocked" : ""}`}>
                      {visibleRowNote(item)}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </section>

        <section
          className="orchestration-work-detail"
          aria-label={`Selected work: ${selected.title}`}
          aria-live="polite"
        >
          <div className="orchestration-detail-heading">
            <div>
              <h2>{selected.title}</h2>
              <p>
                {selected.agent} · {selected.machine}
              </p>
            </div>
          </div>

          {selected.decision === "none" && selected.status === "working" && (
            <p className="orchestration-latest-update">{selected.outcome}</p>
          )}

          {selected.decision !== "none" ? (
            <section className="orchestration-decision" aria-label="Decision">
              <h3>{selected.decisionQuestion}</h3>
              <div className="orchestration-decision-actions">
                <button
                  type="button"
                  className={chosenDecision === "keep-local" ? "is-chosen" : ""}
                  onClick={() => chooseDecision("keep-local")}
                >
                  Keep local
                </button>
                <button
                  type="button"
                  className={chosenDecision === "use-cloud" ? "is-chosen" : ""}
                  onClick={() => chooseDecision("use-cloud")}
                >
                  Use cloud
                </button>
              </div>
              {chosenDecision && (
                <p className="orchestration-local-note">
                  {`Preview choice: ${decisionText(chosenDecision)}; no work was dispatched.`}
                </p>
              )}
            </section>
          ) : selected.status === "blocked" ? (
            <section className="orchestration-blocked" aria-label="Blocked work">
              <h3>{selected.blocker}</h3>
              <p>No action is needed from you. Mina is checking the cleanup results.</p>
            </section>
          ) : null}

          <div className="orchestration-detail-footer">
            <button
              ref={inspectorButton}
              type="button"
              className="orchestration-inspector-trigger"
              aria-haspopup="dialog"
              aria-expanded={inspectorOpen}
              {...trigger}
            >
              Inspect technical receipt
            </button>
          </div>
          <Popover
            open={inspectorOpen}
            onOpenChange={(next) => {
              if (!next) setInspectorOpen(false);
            }}
            anchor={inspectorButton.current}
            label={`${selected.title} technical receipt`}
            className="orchestration-inspector"
            side="top"
            finalFocus={inspectorButton}
          >
            <ReceiptInspector work={selected} onClose={() => setInspectorOpen(false)} />
          </Popover>
        </section>
      </div>
    </main>
  );
}
