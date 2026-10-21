// l10n-allow-file: DEV gallery top-two judge surface, not shipped UI.
import type { CompareRunBoardProps } from "../compare/CompareRunBoard";
import { CompareRunBoard } from "../compare/CompareRunBoard";
import { TimelineRunBoard } from "../timeline/TimelineRunBoard";

export type TournamentRunBoardProps = CompareRunBoardProps;

type JudgeScore = {
  name: string;
  total: number;
  evidence: number;
  recovery: number;
  attach: number;
  review: number;
  placement: number;
};

const judgeScores: JudgeScore[] = [
  {
    name: "Compare",
    total: 28,
    evidence: 6,
    recovery: 5,
    attach: 6,
    review: 6,
    placement: 5,
  },
  {
    name: "Timeline",
    total: 28,
    evidence: 7,
    recovery: 7,
    attach: 5,
    review: 5,
    placement: 4,
  },
  {
    name: "Ops Console",
    total: 25,
    evidence: 5,
    recovery: 5,
    attach: 5,
    review: 5,
    placement: 5,
  },
];

function PlacementRail({ worker }: { worker: string | undefined }) {
  const provider = worker?.split("·")[0]?.trim() || "cloud-vm";
  return (
    <aside className="tournament-placement" aria-labelledby="tournament-placement-title" data-placement-state="pending">
      <div className="tournament-rail-kicker">Placement / admission</div>
      <h2 id="tournament-placement-title">Current routing contract</h2>
      <dl>
        <div>
          <dt>Worker</dt>
          <dd>{provider} → Freestyle (current)</dd>
        </div>
        <div>
          <dt>Adapter</dt>
          <dd>Huge Blue adapter: pending</dd>
        </div>
        <div>
          <dt>Eligibility</dt>
          <dd>account eligibility: control-plane contract pending</dd>
        </div>
      </dl>
      <p>Provider admission is visible as a pending contract; this surface does not claim Huge Blue routing.</p>
    </aside>
  );
}

function JudgeRail() {
  return (
    <aside className="tournament-judge" aria-labelledby="tournament-judge-title">
      <div className="tournament-rail-kicker">Top-two judge</div>
      <div className="tournament-judge-heading">
        <h2 id="tournament-judge-title">Score / rubric</h2>
        <span>35 points</span>
      </div>
      <table>
        <caption>Reviewer scores for the run board candidates</caption>
        <thead>
          <tr>
            <th scope="col">Candidate</th>
            <th scope="col">Total</th>
            <th scope="col">Evidence</th>
            <th scope="col">Recovery</th>
            <th scope="col">Attach</th>
            <th scope="col">Review</th>
            <th scope="col">Placement</th>
          </tr>
        </thead>
        <tbody>
          {judgeScores.map((score) => (
            <tr key={score.name} data-score={score.total}>
              <th scope="row">{score.name}</th>
              <td>
                <strong>{score.total}/35</strong>
              </td>
              <td>{score.evidence}</td>
              <td>{score.recovery}</td>
              <td>{score.attach}</td>
              <td>{score.review}</td>
              <td>{score.placement}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="tournament-judge-note">
        Compare and Timeline advance together; both scored 28/35. Ops Console remains the 25/35 reference.
      </p>
    </aside>
  );
}

export function TournamentRunBoard({ snapshot, recovered, ...callbacks }: TournamentRunBoardProps) {
  const sharedProps: TournamentRunBoardProps = { snapshot, recovered, ...callbacks };
  const currentWorker = snapshot.attempts[0]?.worker;

  return (
    <div className="tournament-run-board" data-tournament-stage="top-two">
      <div className="tournament-shell">
        <header className="tournament-header">
          <div>
            <div className="tournament-eyebrow">RUN BOARD / UI TOURNAMENT</div>
            <h1>Top-two judge</h1>
            <p>Compare and Timeline render the same durable run and replay fixtures at one normal width.</p>
          </div>
          <output className="tournament-capture-receipt" data-testid="tournament-capture-receipt" aria-live="polite">
            Capture path · event {snapshot.cursor} · shared fixtures · normal width
          </output>
        </header>

        <section className="tournament-rails" aria-label="Tournament judge and placement rails">
          <JudgeRail />
          <PlacementRail worker={currentWorker} />
        </section>

        <section className="tournament-panes" aria-label="Top-two run board comparison">
          <section
            className="tournament-pane"
            data-tournament-pane="compare"
            aria-labelledby="tournament-compare-title"
          >
            <header className="tournament-pane-heading">
              <div>
                <span className="tournament-pane-kicker">Candidate A</span>
                <h2 id="tournament-compare-title">
                  Compare <small>28/35</small>
                </h2>
              </div>
              <p>Matrix → review → attach → approve</p>
            </header>
            <CompareRunBoard {...sharedProps} />
          </section>
          <section
            className="tournament-pane"
            data-tournament-pane="timeline"
            aria-labelledby="tournament-timeline-title"
          >
            <header className="tournament-pane-heading">
              <div>
                <span className="tournament-pane-kicker">Candidate B</span>
                <h2 id="tournament-timeline-title">
                  Timeline <small>28/35</small>
                </h2>
              </div>
              <p>Intent → activity → evidence → decision</p>
            </header>
            <TimelineRunBoard {...sharedProps} />
          </section>
        </section>

        <footer className="tournament-footer">
          <span>Top-two decision surface · same run {snapshot.id}</span>
          <span>Provider admission remains pending at the control plane.</span>
        </footer>
      </div>
    </div>
  );
}
