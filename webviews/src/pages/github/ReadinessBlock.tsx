// The page's lead: whether this pull request can merge now, and if not, each gate that refuses it
// (readiness.ts), each one opening to its detail: the receipt that blocks, the failing job's step
// and log end, the hold's label or line. Merged and closed pull requests draw nothing here; the
// header already says so.
import { useState } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../shared/i18n";
import { readiness, type Blocker, type Receipt } from "./readiness";
import type { DashboardChecks, LinkedPullRequest, PullRequestDetails } from "./types";

/** How the block lays out its blockers: a list (shipped), a row of chips, or one line. */
export type ReadinessLayout = "list" | "chips" | "line";

const short = (sha: string) => sha.slice(0, 7);

/** A receipt's findings lines (`[P1] ...`), else its first lines after the verdict. */
function excerpt(receipt: Receipt): string[] {
  const lines = receipt.body
    .split("\n")
    .slice(1)
    .map((line) => line.trim());
  const findings = lines.filter((line) => /^[-*]?\s*\[P\d\]/.test(line));
  return (findings.length ? findings : lines.filter(Boolean)).slice(0, 6);
}

function title(blocker: Blocker, strings: Strings): string {
  const { t, format } = strings;
  switch (blocker.kind) {
    case "review":
      return t("github.ready.review");
    case "verdict":
      return format("github.ready.verdict", blocker.receipt.word, blocker.receipt.model ?? blocker.receipt.reviewer);
    case "hold":
      return t("github.ready.hold");
    case "red":
      return format("github.ready.red", String(blocker.checks.length));
    case "running":
      return format("github.ready.running", String(blocker.count));
    case "main":
      return t("github.ready.main");
    case "draft":
      return t("github.ready.draft");
    case "conflict":
      return t("github.ready.conflict");
    case "github":
      return t(blocker.state === "behind" ? "github.ready.behind" : "github.ready.ruleBlocked");
    case "history":
      return format("github.ready.history", String(blocker.shown), String(blocker.total));
  }
}

/** Whether the blocker has a detail to open. */
function opens(blocker: Blocker): boolean {
  return blocker.kind === "review" || blocker.kind === "verdict" || blocker.kind === "hold" || blocker.kind === "red";
}

function Detail({
  blocker,
  head,
  strings,
  open,
}: {
  blocker: Blocker;
  head: string;
  strings: Strings;
  open: (url: string) => void;
}) {
  const { t, format } = strings;
  switch (blocker.kind) {
    case "review":
      return (
        <div className="gh-ready-detail">
          <p>{format("github.ready.review.detail", short(head))}</p>
          {blocker.ships.length > 0 && <p>{t("github.ready.review.own")}</p>}
          {blocker.older && (
            <p>
              {format("github.ready.review.older", short(blocker.older.sha))}{" "}
              {blocker.older.url && (
                <button type="button" className="gh-row-link" onClick={() => open(blocker.older!.url!)}>
                  {t("github.ready.openReceipt")}
                </button>
              )}
            </p>
          )}
        </div>
      );
    case "verdict":
      return (
        <div className="gh-ready-detail">
          <pre className="gh-ready-excerpt">{excerpt(blocker.receipt).join("\n")}</pre>
          {blocker.receipt.url && (
            <button type="button" className="gh-row-link" onClick={() => open(blocker.receipt.url!)}>
              {t("github.ready.openReceipt")}
            </button>
          )}
        </div>
      );
    case "hold":
      return (
        <div className="gh-ready-detail">
          {blocker.label && <p>{format("github.ready.hold.label", blocker.label)}</p>}
          {blocker.line && <p className="gh-ready-quote">{blocker.line}</p>}
        </div>
      );
    case "red":
      return (
        <ul className="gh-ready-detail gh-ready-jobs">
          {blocker.checks.map((check) => (
            <li key={check.name}>
              <div className="gh-ready-job">
                <span className="gh-ready-job-name" title={check.name}>
                  {check.name}
                </span>
                {check.job?.failure?.step && <span className="gh-muted">{check.job.failure.step}</span>}
                {check.url && (
                  <button type="button" className="gh-row-link" onClick={() => open(check.url!)}>
                    {t("github.ready.openJob")}
                  </button>
                )}
              </div>
              {check.job?.failure?.excerpt && <pre className="gh-ready-excerpt">{check.job.failure.excerpt}</pre>}
            </li>
          ))}
        </ul>
      );
    default:
      return null;
  }
}

export function ReadinessBlock({
  pr,
  details,
  checks,
  strings,
  open,
  layout = "list",
  shownFirst,
}: {
  pr: LinkedPullRequest;
  details: PullRequestDetails | null | undefined;
  checks: DashboardChecks | null | undefined;
  strings: Strings;
  open: (url: string) => void;
  layout?: ReadinessLayout;
  /** The blocker kind whose detail starts open (the gallery's drill-down state). */
  shownFirst?: Blocker["kind"];
}) {
  const { t, format } = strings;
  const state = readiness(pr, details ?? null, checks ?? null);
  // Untouched (undefined), the `shownFirst` blocker is open once the details name it.
  const [picked, setPicked] = useState<string | null | undefined>(undefined);
  const first = state.blockers.findIndex((blocker) => blocker.kind === shownFirst);
  const shown = picked !== undefined ? picked : first >= 0 ? `${shownFirst}-${first}` : null;
  if (state.state !== "ready" && state.state !== "blocked") return null;
  const head = details?.headCommit ?? "";
  const ship = state.ship;
  const key = (blocker: Blocker, index: number) => `${blocker.kind}-${index}`;
  const toggle = (id: string) => setPicked(shown === id ? null : id);
  const shownBlocker = state.blockers.find((blocker, index) => key(blocker, index) === shown);
  // A blocker's row, chip or inline part: a button when it has a detail to open.
  const item = (blocker: Blocker, index: number) => {
    const id = key(blocker, index);
    const label = title(blocker, strings);
    if (!opens(blocker)) {
      return (
        <span key={id} className="gh-ready-blocker" data-kind={blocker.kind}>
          {label}
        </span>
      );
    }
    return (
      <button
        key={id}
        type="button"
        className="gh-ready-blocker"
        data-kind={blocker.kind}
        aria-expanded={shown === id}
        onClick={() => toggle(id)}
      >
        {layout === "list" && (
          <span className="gh-chevron" data-open={shown === id || undefined} aria-hidden="true">
            <Icon name="disclosure.collapsed" size={12} />
          </span>
        )}
        {label}
      </button>
    );
  };
  return (
    <section className="gh-ready" data-state={state.state} data-layout={layout} aria-live="polite">
      <div className="gh-ready-head">
        <span className="gh-ready-glyph" data-check={state.state === "ready" ? "passed" : "failed"} aria-hidden="true">
          <span className="gh-dot" />
        </span>
        <span className="gh-ready-word">
          {t(state.state === "ready" ? "github.ready.ready" : "github.ready.blocked")}
        </span>
        {ship && (
          <span className="gh-ready-ship">
            {ship.url ? (
              <button type="button" className="gh-row-link" onClick={() => open(ship.url!)}>
                {format("github.ready.ship", ship.model ?? ship.reviewer, short(ship.sha))}
              </button>
            ) : (
              format("github.ready.ship", ship.model ?? ship.reviewer, short(ship.sha))
            )}
          </span>
        )}
        {layout === "line" && state.blockers.length > 0 && (
          <span className="gh-ready-inline">{state.blockers.map(item)}</span>
        )}
      </div>
      {layout === "list" && state.blockers.length > 0 && (
        <ul className="gh-ready-list">
          {state.blockers.map((blocker, index) => (
            <li key={key(blocker, index)} className="gh-ready-item" data-kind={blocker.kind}>
              {item(blocker, index)}
              {shown === key(blocker, index) && <Detail blocker={blocker} head={head} strings={strings} open={open} />}
            </li>
          ))}
        </ul>
      )}
      {layout === "chips" && state.blockers.length > 0 && (
        <div className="gh-ready-chips">{state.blockers.map(item)}</div>
      )}
      {layout !== "list" && shownBlocker && <Detail blocker={shownBlocker} head={head} strings={strings} open={open} />}
    </section>
  );
}
