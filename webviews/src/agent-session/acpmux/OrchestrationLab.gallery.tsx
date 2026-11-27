// l10n-allow-file: orchestration fixture labels are a read-only gallery surface.
import { useState } from "react";
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
  task: string;
  health: string;
  lease: string;
  head: string;
  receiptStatus: "running" | "blocked" | "reviewed";
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
    task: "orch-local-01",
    health: "healthy",
    lease: "09:42 remaining",
    head: "4ce7c9c1…",
    receiptStatus: "running",
  },
  {
    id: "build-box",
    label: "Build Box lease",
    description: "Reserved Linux capacity for heavier verification.",
    decision: "hold",
    blocker: "revised controller cleanup receipt",
    next: "Reconcile cleanup evidence before requesting admission.",
    route: "ssh · enrolled host",
    task: "orch-build-box-07",
    health: "degraded",
    lease: "17:30 remaining",
    head: "ce704bfb…",
    receiptStatus: "blocked",
  },
  {
    id: "cloud-fair-share",
    label: "Cloud fair-share",
    description: "Shared capacity with fairness and retry budgets.",
    decision: "wait",
    blocker: "capacity unavailable",
    next: "Keep the proposal queued and re-evaluate when a slot opens.",
    route: "durable lease · cloud-router",
    task: "orch-cloud-12",
    health: "unknown",
    lease: "starts on admission",
    head: "a81f6de2…",
    receiptStatus: "reviewed",
  },
];

const selectBuildBox: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Build Box lease/ });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Build Box lease" }));
};

export function OrchestrationLab({ initialStrategy = "local-queue" }: { initialStrategy?: string }) {
  const [selectedId, setSelectedId] = useState(initialStrategy);
  const selected = strategies.find((strategy) => strategy.id === selectedId) ?? strategies[0];
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
        <fieldset
          className="orchestration-gallery-routes"
          style={{ border: 0, minInlineSize: 0, margin: 0, padding: 0 }}
          aria-label="Select a route"
        >
          {strategies.map((strategy) => {
            const selectedRoute = strategy.id === selected.id;
            return (
              <button
                key={strategy.id}
                className={`orchestration-gallery-route${selectedRoute ? " is-selected" : ""}`}
                type="button"
                aria-pressed={selectedRoute}
                onClick={() => setSelectedId(strategy.id)}
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
        </fieldset>
      </section>

      <section
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
        <pre aria-label="Non-contract display sample">
          {JSON.stringify(
            {
              receipt: {
                schema_version: 1,
                task_id: selected.task,
                transport: selected.route.split(" · ")[0],
                stage: "preview",
                state: selected.receiptStatus,
                status: selected.receiptStatus,
                acceptance: "advisory",
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
                authorization: "disabled",
              },
            },
            null,
            2,
          )}
        </pre>
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
  covers: ["agent-session/acpmux/App.tsx#AcpmuxApp"],
  styles: () => import("./OrchestrationLab.gallery.css"),
  load: async () => OrchestrationLab,
  variants: {
    "local-queue": {
      note: "Fixture-only local route with an explicit trust boundary.",
      props: { initialStrategy: "local-queue" },
    },
    "build-box": {
      note: "Held route with cleanup evidence as the blocker.",
      props: { initialStrategy: "build-box" },
      play: selectBuildBox,
    },
    "cloud-fair-share": {
      note: "Queued route with capacity unavailable.",
      props: { initialStrategy: "cloud-fair-share" },
    },
  },
});
