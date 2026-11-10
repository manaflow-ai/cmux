// l10n-allow-file: bench fixture text (pull request titles, a clock), not shipped UI.
// The same content drawn two ways, for extension-parity.bench.ts:
//   #case=clock&arm=scene   the example clock app's scene (examples/extensions/clock: a VStack, the time's
//                           Text and the date's Text) in SceneRenderer, as a New Tab widget draws it; an
//                           update is the one `update` op of the time's Text node a tick sends.
//   #case=clock&arm=react   the first-party clock (NewTabExtras with the `clock` widget); an update is the
//                           page's `now` a minute later.
//   #case=list&arm=scene    30 pull request Rows in a VStack (what an app's PR list sends); an update is one
//                           row's subtitle.
//   #case=list&arm=react    Session Info's first-party Changes section with the same 30 pull requests, opened
//                           whole; an update is one pull request's live status (its title).
// `window.benchUpdate(round)` makes update `round` synchronously (flushSync) and forces style and layout,
// so the time it takes is that update's main-thread work; a React Profiler counts the commits.
/// <reference types="vite/client" />
import { Profiler, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { SceneRenderer } from "../../src/apps/scene/SceneRenderer";
import { SceneStore, type SceneOp } from "../../src/apps/scene/store";
import { mockClockScene } from "../../src/apps/scene/panelsMock";
import { NewTabExtras } from "../../src/agent-session/acpmux/newtab/NewTabExtras";
import { ChangesSection } from "../../src/agent-session/acpmux/session-info/ChangesSection";
import type { SessionInfoPullRequestStatus } from "../../src/agent-session/acpmux/session-info/changesSectionModel";
import type { SummaryPullRequest } from "../../src/agent-session/acpmux/summary/sessionSummary";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/session-info/sessionInfo.css";

const params = new URLSearchParams(location.hash.slice(1));
const benchCase = params.get("case") === "list" ? "list" : "clock";
const arm = params.get("arm") === "react" ? "react" : "scene";
const ROWS = 30;
const NOW = Date.UTC(2026, 10, 10, 17, 42);

declare global {
  interface Window {
    benchReady: boolean;
    /// Commits under the Profiler: [commitTime, actualDuration].
    benchCommits: [number, number][];
    benchUpdate(round: number): void;
  }
}
window.benchCommits = [];

const prs: SummaryPullRequest[] = Array.from({ length: ROWS }, (_, index) => ({
  url: `https://github.com/acme/atlas/pull/${200 + index}`,
  repo: "acme/atlas",
  number: 200 + index,
  title: `Keep chat drafts on reconnect, part ${index + 1}`,
  state: "open",
  opened: true,
  changed: true,
}));
const status = (index: number, round: number): SessionInfoPullRequestStatus => ({
  title: round ? `Keep chat drafts on reconnect, part ${index + 1} (${round})` : prs[index]!.title!,
  state: "open",
  checks: "passing",
  additions: 40 + index,
  deletions: 3,
});
const subtitle = (index: number, round: number) => `acme/atlas #${200 + index} · ${round ? `${round} min ago` : "now"}`;

const onRender = (_id: string, _phase: string, actualDuration: number, _base: number, _start: number, commit: number) =>
  window.benchCommits.push([commit, actualDuration]);
const forceLayout = () => void document.body.offsetHeight;
const noDispatch = () => undefined;

function SceneArm({ store }: { store: SceneStore }) {
  return (
    <div className="nt-screen" data-template="minimal">
      <div className="nt-extras">
        <section className="nt-ext-widget" data-size={benchCase === "list" ? "wide" : "small"}>
          <SceneRenderer store={store} dispatch={noDispatch} />
        </section>
      </div>
    </div>
  );
}

let setReact: ((round: number) => void) | undefined;
function ReactArm() {
  const [round, setRound] = useState(0);
  setReact = setRound;
  if (benchCase === "clock")
    return (
      <div className="nt-screen" data-template="minimal">
        <NewTabExtras widgets={CLOCK_ONLY} now={NOW + round * 60_000} />
      </div>
    );
  return (
    <div className="acpmux-session-info" style={{ width: 340 }}>
      <ChangesSection pullRequests={prs} statuses={statusesAt(round)} />
    </div>
  );
}
const CLOCK_ONLY: ReadonlySet<string> = new Set(["clock"]);
/// One status object per pull request, kept across rounds; an update replaces only the changed one.
let statuses: Record<string, SessionInfoPullRequestStatus> = Object.fromEntries(
  prs.map((pr, index) => [pr.url, status(index, 0)]),
);
function statusesAt(round: number): Record<string, SessionInfoPullRequestStatus> {
  if (!round) return statuses;
  const index = (round * 7) % ROWS;
  statuses = { ...statuses, [prs[index]!.url]: status(index, round) };
  return statuses;
}

const store = new SceneStore();
if (arm === "scene") {
  if (benchCase === "clock") store.apply(mockClockScene(NOW), true);
  else
    store.apply(
      [
        { op: "create", id: "list", type: "VStack", props: { spacing: 0 } },
        ...prs.map((pr, index): SceneOp => ({
          op: "create",
          id: `pr-${index}`,
          type: "Row",
          props: { title: pr.title!, subtitle: subtitle(index, 0), symbol: "arrow.triangle.pull", tint: "success" },
        })),
        { op: "children", id: "list", children: prs.map((_, index) => `pr-${index}`) },
        { op: "root", id: "list" },
      ],
      true,
    );
}

window.benchUpdate = (round: number) => {
  if (arm === "scene") {
    const ops: SceneOp[] =
      benchCase === "clock"
        ? [
            {
              op: "update",
              id: "time",
              props: {
                text: new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" }).format(
                  NOW + round * 60_000,
                ),
              },
            },
          ]
        : [{ op: "update", id: `pr-${(round * 7) % ROWS}`, props: { subtitle: subtitle((round * 7) % ROWS, round) } }];
    flushSync(() => store.apply(ops));
  } else flushSync(() => setReact!(round));
  forceLayout();
};

const root = createRoot(document.getElementById("root")!);
flushSync(() =>
  root.render(
    <Profiler id="arm" onRender={onRender}>
      {arm === "scene" ? <SceneArm store={store} /> : <ReactArm />}
    </Profiler>,
  ),
);
// Changes shows five rows and Show more: open it, so both list arms draw all 30 rows.
document.querySelector<HTMLButtonElement>(".acpmux-session-info-pr-fold")?.click();
requestAnimationFrame(() => {
  window.benchReady = true;
});
