// l10n-allow-file: gallery-only design study (sample branch, title and check names), not shipped UI.
// Turn end to an open pull request with its checks in at most 3 clicks (RFD 0167 amendment 1,
// row 8; Leo, 2026-11-24: "if you havent already you guys can also look at chatgpt's rfd 162 and go
// even further beyond"). Three placements of one action, each drawn from the pane's real pieces:
// the edited-files card (EditedFilesCard), the turn's action row (MessageActions), the header's
// pull request chip and its checks rows (PullRequestChip, header.css), the composer's quiet row
// (ComposerFoot) and the kit Button. No production call site renders this file.
//
// - `turn-row`: "Open pull request" at the end of the last turn's action row; once opened it is
//   the real PR chip with a checks ring and a one-line summary. 1 click to the PR and its summary,
//   2 to each check (the chip's popover).
// - `changes-foot`: the edited-files card grows a foot: the branch, its base and Open pull
//   request; once opened the foot is the PR and every check, failing first. 1 click to all of it.
// - `composer-chip`: a branch chip in the composer's quiet row; its menu has Open pull request, then
//   the chip reads the PR and its ring, and opens the checks. 3 clicks.
//
// Every state is static data: nothing here pushes, commits or calls GitHub.
import type { ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { ComposerFoot } from "../ComposerFoot";
import { EditedFilesCard } from "../conversation/EditedFilesCard";
import { ForkButton, MessageCopy, MessageFooterRow, MessageMore, PinButton } from "../conversation/MessageActions";
import { PullRequestChip } from "../header/PullRequestChip";
import type { HeaderCheck, HeaderPullRequest } from "../header/headerState";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";

export type TurnToPullRequestDesign = "turn-row" | "changes-foot" | "composer-chip";
export type TurnToPullRequestState = "ended" | "opening" | "running" | "green" | "red";

export const TURN_TO_PR_STATES: readonly TurnToPullRequestState[] = ["ended", "opening", "running", "green", "red"];

const BRANCH = "retry-backoff";
const BASE = "main";
const REPLY = "Done: the client retries through withRetry, three tries 250 ms apart, with tests.";

const CHECKS: Record<"running" | "green" | "red", HeaderCheck[]> = {
  running: [
    { name: "web-lint", state: "passed" },
    { name: "typecheck", state: "passed" },
    { name: "unit tests", state: "pending" },
    { name: "gallery", state: "pending" },
    { name: "compile (Swift)", state: "pending" },
  ],
  green: [
    { name: "web-lint", state: "passed" },
    { name: "typecheck", state: "passed" },
    { name: "unit tests", state: "passed" },
    { name: "gallery", state: "passed" },
    { name: "compile (Swift)", state: "passed" },
  ],
  red: [
    { name: "unit tests", state: "failed" },
    { name: "web-lint", state: "passed" },
    { name: "typecheck", state: "passed" },
    { name: "gallery", state: "passed" },
    { name: "compile (Swift)", state: "passed" },
  ],
};

function pullRequestFor(state: "running" | "green" | "red"): HeaderPullRequest {
  const checkList = CHECKS[state];
  return {
    url: "https://github.com/example/atlas-web/pull/1284",
    number: 1284,
    title: "Retry fetches with backoff",
    state: "open",
    review: "",
    mergeable: state === "running" ? "" : "mergeable",
    checks: {
      state: state === "running" ? "pending" : state === "green" ? "passing" : "failing",
      passed: checkList.filter((check) => check.state === "passed").length,
      total: checkList.length,
    },
    checkList,
  };
}

/// A ring of the checks: passed, failed and pending arcs on the muted track (14 px, the row icon size).
export function ChecksRing({ checks, size = 14 }: { checks: readonly HeaderCheck[]; size?: number }) {
  const radius = 5.5;
  const length = 2 * Math.PI * radius;
  const total = Math.max(checks.length, 1);
  const passed = checks.filter((check) => check.state === "passed").length;
  const failed = checks.filter((check) => check.state === "failed").length;
  const arc = (count: number, offset: number, color: string) =>
    count > 0 && (
      <circle
        cx="7"
        cy="7"
        r={radius}
        fill="none"
        stroke={color}
        strokeWidth="2"
        strokeDasharray={`${(count / total) * length} ${length}`}
        strokeDashoffset={-(offset / total) * length}
        transform="rotate(-90 7 7)"
      />
    );
  return (
    <svg className="ttp-ring" width={size} height={size} viewBox="0 0 14 14" aria-hidden="true">
      <circle cx="7" cy="7" r={radius} fill="none" stroke="var(--agent-border)" strokeWidth="2" />
      {arc(failed, 0, "var(--agent-status-failure)")}
      {arc(passed, failed, "var(--agent-status-success)")}
    </svg>
  );
}

function checksSummary(state: "running" | "green" | "red"): string {
  const pr = pullRequestFor(state);
  const { passed, total } = pr.checks;
  if (state === "green") return `All ${total} checks passed`;
  if (state === "red")
    return `${pr.checkList
      .filter((check) => check.state === "failed")
      .map((check) => check.name)
      .join(", ")} failed · ${passed} of ${total} passed`;
  return `${passed} of ${total} checks passed, ${total - passed} running`;
}

/// The header's checks rows (header.css `.acpmux-pr-checks`), failing first, as the chip's popover lists them.
function CheckRows({ checks }: { checks: readonly HeaderCheck[] }) {
  return (
    <ul className="acpmux-pr-checks ttp-checks">
      {checks.map((check) => (
        <li key={check.name} className="acpmux-pr-check" data-state={check.state}>
          <span>{check.name}</span>
          {check.state === "failed" && <span className="ttp-check-end">Details</span>}
          {check.state === "pending" && <span className="ttp-check-end">Running</span>}
        </li>
      ))}
    </ul>
  );
}

/// The next action a finished set of checks offers: Merge on green, Ask the agent to fix on red.
function NextAction({ state }: { state: TurnToPullRequestState }) {
  if (state === "green")
    return (
      <Button size="sm" variant="solid" className="ttp-next">
        Merge
      </Button>
    );
  if (state === "red")
    return (
      <Button size="sm" className="ttp-next">
        Ask agent to fix
      </Button>
    );
  return null;
}

function OpenButton({ busy, label = "Open pull request" }: { busy: boolean; label?: string }) {
  return (
    <Button size="sm" className="ttp-open" disabled={busy} data-busy={busy ? "" : undefined}>
      <Icon name={busy ? "status.inprogress" : "git.pullrequest"} size={12} />
      {busy ? `Pushing ${BRANCH}…` : label}
    </Button>
  );
}

function BranchLabel() {
  return (
    <span className="ttp-branch">
      <Icon name="git.branch" size={12} />
      <span className="ttp-branch-name">{BRANCH}</span>
      <span className="ttp-muted">into {BASE}</span>
    </span>
  );
}

/// The last turn's action row (TurnRows.tsx TurnFooter's buttons), shown at rest as the chat's last turn's is.
function TurnRow({ children }: { children?: ReactNode }) {
  return (
    <div className="cv-turn-actions ttp-turn-actions">
      <MessageFooterRow className="cv-turn-footer-row">
        <span className="cv-turn-action-group">
          <MessageCopy text={REPLY} />
          <ForkButton throughSeq={3} onFork={() => undefined} />
          <PinButton rowId="ttp-answer" />
          <MessageMore rowId="ttp-answer" />
        </span>
        {children}
      </MessageFooterRow>
    </div>
  );
}

function TurnRowDesign({ state }: { state: TurnToPullRequestState }) {
  if (state === "ended" || state === "opening")
    return (
      <TurnRow>
        <span className="ttp-row-pr">
          <OpenButton busy={state === "opening"} />
        </span>
      </TurnRow>
    );
  const pr = pullRequestFor(state);
  return (
    <TurnRow>
      <span className="ttp-row-pr" data-state={state}>
        <PullRequestChip pullRequest={pr} />
        <ChecksRing checks={pr.checkList} />
        <span className="ttp-summary">{checksSummary(state)}</span>
        <NextAction state={state} />
      </span>
    </TurnRow>
  );
}

function ChangesFoot({ state }: { state: TurnToPullRequestState }) {
  if (state === "ended" || state === "opening")
    return (
      <div className="ttp-foot">
        <div className="ttp-foot-line">
          <BranchLabel />
          <OpenButton busy={state === "opening"} />
        </div>
      </div>
    );
  const pr = pullRequestFor(state);
  return (
    <div className="ttp-foot" data-state={state}>
      <div className="ttp-foot-line">
        <span className="ttp-foot-pr">
          <Icon name="git.pullrequest" size={12} />
          <a className="ttp-pr-link" href={pr.url}>
            #{pr.number} {pr.title}
          </a>
        </span>
        <span className="ttp-foot-checks">
          <ChecksRing checks={pr.checkList} />
          <span className="ttp-muted">
            {pr.checks.passed}/{pr.checks.total}
          </span>
        </span>
      </div>
      {state === "green" ? (
        <div className="ttp-foot-line">
          <span className="ttp-summary">{checksSummary(state)}</span>
          <NextAction state={state} />
        </div>
      ) : (
        <>
          <CheckRows checks={pr.checkList} />
          {state === "red" && (
            <div className="ttp-foot-line ttp-foot-end">
              <NextAction state={state} />
            </div>
          )}
        </>
      )}
    </div>
  );
}

function ComposerChip({ state }: { state: TurnToPullRequestState }) {
  if (state === "ended" || state === "opening")
    return (
      <span className="ttp-chip" data-open={state === "ended" ? "" : undefined}>
        <Icon name={state === "opening" ? "status.inprogress" : "git.branch"} size={12} />
        {state === "opening" ? `Pushing ${BRANCH}…` : BRANCH}
        {state === "ended" && <span className="ttp-muted">↑2</span>}
      </span>
    );
  const pr = pullRequestFor(state);
  return (
    <span className="ttp-chip" data-open="" data-state={state}>
      <Icon name="git.pullrequest" size={12} />#{pr.number}
      <ChecksRing checks={pr.checkList} size={12} />
      <span className="ttp-muted">
        {pr.checks.passed}/{pr.checks.total}
      </span>
    </span>
  );
}

/// What the composer chip's click opens: its menu (turn ended) or the PR's checks (once opened).
function ComposerPopup({ state }: { state: TurnToPullRequestState }) {
  if (state === "opening") return null;
  if (state === "ended")
    return (
      <div className="ttp-popup ttp-menu" role="menu">
        <div className="ttp-menu-row" data-hot="">
          <Icon name="git.pullrequest" size={12} />
          Open pull request
          <span className="ttp-muted ttp-menu-end">into {BASE}</span>
        </div>
        <div className="ttp-menu-row">
          <Icon name="action.sync" size={12} />
          Push
        </div>
        <div className="ttp-menu-row">
          <Icon name="diff.file" size={12} />
          View changes
        </div>
      </div>
    );
  const pr = pullRequestFor(state);
  return (
    <div className="ttp-popup acpmux-pr-status">
      <a className="acpmux-pr-title" href={pr.url}>
        {pr.title}
      </a>
      <div className="acpmux-pr-facts">
        <span className="acpmux-pr-state" data-state="open">
          Open #{pr.number}
        </span>
      </div>
      <CheckRows checks={pr.checkList} />
      {state !== "running" && (
        <div className="ttp-foot-line ttp-foot-end">
          <NextAction state={state} />
        </div>
      )}
    </div>
  );
}

function Composer({ design, state }: { design: TurnToPullRequestDesign; state: TurnToPullRequestState }) {
  const chip = design === "composer-chip";
  return (
    <div className="ttp-composer">
      {chip && <ComposerPopup state={state} />}
      <div className="ttp-composer-box">
        <span className="ttp-muted">Reply…</span>
      </div>
      <ComposerFoot>
        <span className="ttp-foot-mode">Ask before edits</span>
        <span className="ttp-foot-spacer" />
        {chip && <ComposerChip state={state} />}
        <span className="ttp-foot-model">Opus 5.5 Medium</span>
      </ComposerFoot>
    </div>
  );
}

const CAPTIONS: Record<TurnToPullRequestDesign, Record<TurnToPullRequestState, string>> = {
  "turn-row": {
    ended: "Turn just ended · 0 clicks",
    opening: "Click 1: Open pull request · pushing, then opening",
    running: "PR open, checks running · 1 click (each check: click 2, the chip)",
    green: "Checks green · Merge is the next click",
    red: "Checks red · Ask agent to fix is the next click",
  },
  "changes-foot": {
    ended: "Turn just ended · 0 clicks",
    opening: "Click 1: Open pull request · pushing, then opening",
    running: "PR open, every check listed · 1 click",
    green: "Checks green · Merge is the next click",
    red: "Checks red · the failing check first, Ask agent to fix",
  },
  "composer-chip": {
    ended: "Turn just ended · click 1 opens the branch chip's menu",
    opening: "Click 2: Open pull request · pushing, then opening",
    running: "Click 3: the PR chip shows every check · 3 clicks",
    green: "Checks green · Merge in the chip's panel",
    red: "Checks red · Ask agent to fix in the chip's panel",
  },
};

function Scene({
  design,
  state,
  row,
}: {
  design: TurnToPullRequestDesign;
  state: TurnToPullRequestState;
  row: AcpmuxRow;
}) {
  return (
    <div className="ttp-scene" data-design={design} data-state={state}>
      <div className="ttp-transcript">
        <p className="ttp-reply">{REPLY}</p>
        <div className="ttp-card" data-foot={design === "changes-foot" ? "" : undefined}>
          <EditedFilesCard row={row} sessionId="gallery" onOpenDiff={() => undefined} />
          {design === "changes-foot" && <ChangesFoot state={state} />}
        </div>
        {design === "turn-row" ? <TurnRowDesign state={state} /> : <TurnRow />}
      </div>
      <Composer design={design} state={state} />
    </div>
  );
}

export type TurnToPullRequestDesignsProps = {
  design: TurnToPullRequestDesign;
  /// One state, or every state stacked with its caption (the sheet).
  state?: TurnToPullRequestState;
  row: AcpmuxRow;
};

export function TurnToPullRequestDesigns({ design, state, row }: TurnToPullRequestDesignsProps) {
  const states = state ? [state] : TURN_TO_PR_STATES;
  return (
    <div className="acpmux-shell ttp" data-gallery-capture="">
      {states.map((each) => (
        <section key={each} className="ttp-frame" aria-label={CAPTIONS[design][each]}>
          <h3 className="ttp-caption">{CAPTIONS[design][each]}</h3>
          <Scene design={design} state={each} row={row} />
        </section>
      ))}
    </div>
  );
}
