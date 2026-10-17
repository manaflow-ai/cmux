// l10n-allow-file: orchestration fixture labels are a read-only gallery surface.
import { useRef, useState, type KeyboardEvent } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

type Strategy = {
  id: string;
  label: string;
  description: string;
  decision: "admit" | "hold" | "wait";
  blocker: string;
  next: string;
  route: string;
  transport: "loopback" | "ssh" | "lease";
  task: string;
  health: string;
  lease: string;
  head: string;
  receiptStatus: "running" | "blocked" | "reviewed";
  state: "submitted" | "running";
};

const strategies: Strategy[] = [
  {
    id: "local-queue",
    label: "Local queue",
    description: "Fast feedback for short, interactive work.",
    decision: "admit",
    blocker: "available",
    next: "Run the next bounded task and record its receipt.",
    route: "loopback · local-supervisor",
    transport: "loopback",
    task: "orch-local-01",
    health: "healthy",
    lease: "09:42 remaining",
    head: "4ce7c9c1…",
    receiptStatus: "running",
    state: "running",
  },
  {
    id: "huge-blue",
    label: "Huge Blue lease",
    description: "Reserved Linux capacity for heavier verification.",
    decision: "hold",
    blocker: "revised controller cleanup receipt",
    next: "Reconcile cleanup evidence before requesting admission.",
    route: "ssh · enrolled host",
    transport: "ssh",
    task: "orch-huge-blue-07",
    health: "degraded",
    lease: "17:30 remaining",
    head: "ce704bfb…",
    receiptStatus: "blocked",
    state: "submitted",
  },
  {
    id: "cloud-fair-share",
    label: "Cloud fair-share",
    description: "Shared capacity with fairness and retry budgets.",
    decision: "wait",
    blocker: "capacity unavailable",
    next: "Keep the proposal queued and re-evaluate when a slot opens.",
    route: "durable lease · cloud-router",
    transport: "lease",
    task: "orch-cloud-12",
    health: "unknown",
    lease: "starts on admission",
    head: "a81f6de2…",
    receiptStatus: "reviewed",
    state: "submitted",
  },
];

const selectHugeBlue: Play = async (ctx) => {
  await ctx.click({ role: "radio", name: /Huge Blue lease/ });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Huge Blue lease" }));
};

export function OrchestrationLab({ initialStrategy = "local-queue" }: { initialStrategy?: string }) {
  const [selectedId, setSelectedId] = useState(initialStrategy);
  const routeRefs = useRef<Record<string, HTMLButtonElement | null>>({});
  const selected = strategies.find((strategy) => strategy.id === selectedId) ?? strategies[0];
  const handleRouteKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const direction =
      event.key === "ArrowRight" || event.key === "ArrowDown"
        ? 1
        : event.key === "ArrowLeft" || event.key === "ArrowUp"
          ? -1
          : 0;
    const targetIndex =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? strategies.length - 1
          : direction
            ? (index + direction + strategies.length) % strategies.length
            : -1;
    if (targetIndex < 0 && event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    if (targetIndex >= 0) {
      const target = strategies[targetIndex];
      setSelectedId(target.id);
      routeRefs.current[target.id]?.focus();
    } else {
      setSelectedId(event.currentTarget.dataset.routeId ?? selected.id);
    }
  };
  return (
    <main className="orchestration-gallery" data-orchestration-lab>
      <header className="orchestration-gallery-header">
        <div>
          <p className="orchestration-gallery-kicker">Fixture-only comparison surface</p>
          <h1>Orchestration lab</h1>
          <p>Compare route decisions before a worker, provider, scheduler, or dispatch path exists.</p>
        </div>
        <div className="orchestration-gallery-trust" role="note" aria-label="Orchestration trust state">
          <strong>Preview only</strong>
          <span>No task dispatched</span>
          <span>Authorization disabled</span>
          <span>Proposal advisory</span>
          <span>Trust override preview only</span>
        </div>
      </header>

      <section className="orchestration-gallery-compare" aria-label="Route comparison">
        <div className="orchestration-gallery-section-heading">
          <div>
            <span className="orchestration-gallery-kicker">Route comparison</span>
            <p>Choose a route to inspect its receipt-shaped fixture and action path.</p>
          </div>
          <span className="orchestration-gallery-hint">Arrow keys · Enter</span>
        </div>
        <div className="orchestration-gallery-routes" role="radiogroup" aria-label="Select a route">
          {strategies.map((strategy, index) => {
            const selectedRoute = strategy.id === selected.id;
            return (
              <button
                key={strategy.id}
                className={`orchestration-gallery-route${selectedRoute ? " is-selected" : ""}`}
                type="button"
                role="radio"
                aria-checked={selectedRoute}
                aria-controls="orchestration-gallery-receipt"
                tabIndex={selectedRoute ? 0 : -1}
                data-route-id={strategy.id}
                ref={(element) => {
                  routeRefs.current[strategy.id] = element;
                }}
                onClick={() => setSelectedId(strategy.id)}
                onKeyDown={(event) => handleRouteKeyDown(event, index)}
              >
                <span>
                  <strong>{strategy.label}</strong>
                  <b data-decision={strategy.decision}>{strategy.decision}</b>
                </span>
                <small>Blocker · {strategy.blocker}</small>
                <small>Next · {strategy.next}</small>
              </button>
            );
          })}
        </div>
      </section>

      <section
        id="orchestration-gallery-receipt"
        className="orchestration-gallery-inspector"
        aria-live="polite"
        aria-label={`${selected.label} receipt preview`}
      >
        <div className="orchestration-gallery-section-heading">
          <div>
            <span className="orchestration-gallery-kicker">Receipt preview · display sample</span>
            <h2>{selected.label}</h2>
          </div>
          <b data-status={selected.receiptStatus}>{selected.receiptStatus}</b>
        </div>
        <dl className="orchestration-gallery-summary">
          <div>
            <dt>Task</dt>
            <dd>{selected.task}</dd>
          </div>
          <div>
            <dt>Route</dt>
            <dd>{selected.route}</dd>
          </div>
          <div>
            <dt>Health</dt>
            <dd>{selected.health}</dd>
          </div>
          <div>
            <dt>Lease</dt>
            <dd>{selected.lease}</dd>
          </div>
          <div>
            <dt>Source head</dt>
            <dd>{selected.head}</dd>
          </div>
          <div>
            <dt>Acceptance</dt>
            <dd>advisory fixture</dd>
          </div>
        </dl>
        <div className="orchestration-gallery-action-path" aria-label="Action path">
          <span>
            <b>1</b>
            <strong>Decision</strong>
            {selected.decision}
          </span>
          <span>
            <b>2</b>
            <strong>Blocker</strong>
            {selected.blocker}
          </span>
          <span className="is-next">
            <b>3</b>
            <strong>Next safe action</strong>
            {selected.next}
          </span>
        </div>
        <details className="orchestration-gallery-json">
          <summary>Show non-contract JSON sample</summary>
          <pre aria-label="Non-contract display sample">
            {JSON.stringify(
              {
                receipt: {
                  schema_version: 1,
                  message_id: "redacted",
                  task_id: selected.task,
                  in_reply_to: "redacted",
                  sender: "cmux-chat",
                  recipient: "fixture-supervisor",
                  transport: selected.transport,
                  host_id: "fixture-host",
                  session_id: "redacted",
                  root_id: "gallery-fixture",
                  owner: "gallery-fixture",
                  kind: "progress",
                  authority_ref: "user-request:orchestration-lab-gallery-prototype",
                  stage: "working",
                  state: selected.state,
                  status: selected.receiptStatus,
                  acceptance: "accepted",
                  repository: "cmux",
                  worktree: "agent-chat",
                  branch: "fixture",
                  base_sha: "1".repeat(64),
                  head_sha: "2".repeat(64),
                  artifact_sha: "3".repeat(64),
                  command: `gallery.fixture --strategy ${selected.id}`,
                  assertion_count: 0,
                  artifacts: { preview: "fixture-only" },
                  evidence: [],
                  gap: selected.blocker,
                  next_action: selected.next,
                },
                fixture_context: {
                  display_only: true,
                  no_dispatch: true,
                  redaction: "Deterministic synthetic values; no command or task ran.",
                  route: { id: selected.id, label: selected.route, health: selected.health, lease: selected.lease },
                  guidance: { manifest: "sha256:fixture", resolution: "fixture-only; no worker guidance loaded" },
                  proposal: { kind: "wait", detail: selected.next },
                  next_work: null,
                  authorization: "disabled",
                },
              },
              null,
              2,
            )}
          </pre>
        </details>
      </section>
    </main>
  );
}

export default componentEntry<{ initialStrategy?: string }>({
  id: "agent-pane.orchestration-lab",
  title: "Orchestration lab",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 780,
  widths: { narrow: 520, normal: 860, wide: 1160 },
  anchors: [{ selector: "[data-orchestration-lab]" }],
  covers: ["agent-session/acpmux/OrchestrationLab.gallery.tsx#OrchestrationLab"],
  styles: () => import("./OrchestrationLab.gallery.css"),
  load: async () => OrchestrationLab,
  variants: {
    "local-queue": {
      note: "Fixture-only local route with an explicit trust boundary.",
      props: { initialStrategy: "local-queue" },
    },
    "huge-blue": {
      note: "Held route with cleanup evidence as the blocker.",
      props: { initialStrategy: "huge-blue" },
      play: selectHugeBlue,
    },
    "cloud-fair-share": {
      note: "Queued route with capacity unavailable.",
      props: { initialStrategy: "cloud-fair-share" },
    },
  },
});
