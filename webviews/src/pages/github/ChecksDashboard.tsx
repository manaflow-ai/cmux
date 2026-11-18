// The GitHub page's CI dashboard (Leo, 2026-11-07: "we can use this as a way to follow up and just
// keep track of CI as it runs ... here's your big dashboard"): the tally and the share done with an
// ETA on top; failing jobs first with the step that failed and the end of its log; running jobs
// with how long they have run; queued; then every passed job folded into one line. A matrix's
// shards are one row with a pip per shard. Re-run failed reruns the failed jobs through gh's
// normal path on a click.
import { useEffect, useState, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import {
  dashboardBuckets,
  dashboardRows,
  dashboardSummary,
  duration,
  elapsed,
  failedRuns,
  type DashboardRow,
} from "./checksModel";
import type { GitHubStore } from "./store";
import type { DashboardChecks, DashboardJob, RerunState } from "./types";

/** Re-renders once a second while a job runs and the page is shown, for its elapsed time; stops when none runs. */
function useTicking(running: boolean) {
  const [, setTick] = useState(0);
  useEffect(() => {
    if (!running) return;
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") setTick((tick) => tick + 1);
    }, 1000);
    return () => clearInterval(timer);
  }, [running]);
}

export function ChecksDashboard({
  checks,
  rerun,
  store,
  strings,
  now,
  open,
}: {
  checks: DashboardChecks;
  rerun: RerunState;
  store: GitHubStore;
  strings: Strings;
  now: () => number;
  open: (url: string) => void;
}) {
  const { t } = strings;
  const [showPassed, setShowPassed] = useState(false);
  const rows = dashboardRows(checks.jobs);
  const buckets = dashboardBuckets(rows);
  const at = now();
  const summary = dashboardSummary(checks.jobs, at);
  useTicking(summary.running > 0);
  const runs = failedRuns(checks.jobs);
  const tally: [string, number, string][] = [
    ["failed", summary.failed, "github.checks.failing"],
    ["running", summary.running, "github.checks.running"],
    ["queued", summary.queued, "github.checks.queued"],
    ["passed", summary.passed, "github.checks.passed"],
  ];
  return (
    <section className="gh-section gh-ci">
      <h2 className="gh-section-title">
        <span>{t("github.checks")}</span>
        {runs.length > 0 && (
          <button
            type="button"
            className="gh-button gh-ci-rerun"
            disabled={rerun.phase === "running"}
            onClick={() => void store.rerunFailed()}
          >
            {t(rerun.phase === "running" ? "github.checks.rerunning" : "github.checks.rerun")}
          </button>
        )}
      </h2>
      {rerun.phase === "failed" && rerun.message && (
        <p className="gh-failure gh-ci-note" role="alert">
          {rerun.message}
        </p>
      )}
      {rerun.phase === "started" && (
        <p className="gh-muted gh-ci-note" aria-live="polite">
          {t("github.checks.rerunStarted")}
        </p>
      )}
      {checks.truncated && <p className="gh-muted gh-ci-note">{t("github.checks.more")}</p>}
      {summary.total === 0 ? (
        <p className="gh-muted">{t("github.checks.none")}</p>
      ) : (
        <>
          <div className="gh-ci-summary">
            <div className="gh-ci-tally">
              {tally
                .filter(([, count]) => count > 0)
                .map(([state, count, label]) => (
                  <span key={state} className="gh-ci-count" data-check={state === "running" ? "pending" : state}>
                    <span className="gh-dot" aria-hidden="true" />
                    <span className="gh-count">{count}</span>
                    <span>{t(label)}</span>
                  </span>
                ))}
            </div>
            <span className="gh-muted gh-ci-progress-text">
              {strings.format("github.checks.done", String(summary.passed + summary.failed), String(summary.total))}
              {summary.eta != null &&
                summary.eta > 0 &&
                ` · ${strings.format("github.checks.eta", duration(summary.eta, strings.language))}`}
            </span>
          </div>
          {/* Each job's share of one bar, in the order the lists below go. */}
          <div className="gh-ci-bar" aria-hidden="true">
            {summary.failed > 0 && <span data-check="failed" style={{ flexGrow: summary.failed }} />}
            {summary.running > 0 && <span data-check="pending" style={{ flexGrow: summary.running }} />}
            {summary.queued > 0 && <span data-check="queued" style={{ flexGrow: summary.queued }} />}
            {summary.passed > 0 && <span data-check="passed" style={{ flexGrow: summary.passed }} />}
          </div>
          {buckets.failed.length > 0 && (
            <Group label={t("github.checks.failing")}>
              {buckets.failed.map((row) => (
                <Row key={row.key} row={row} strings={strings} at={at} open={open}>
                  {row.jobs
                    .filter((job) => job.state === "failed")
                    .map((job) => (
                      <Failure key={job.id || job.name} job={job} row={row} strings={strings} />
                    ))}
                </Row>
              ))}
            </Group>
          )}
          {buckets.running.length > 0 && (
            <Group label={t("github.checks.running")}>
              {buckets.running.map((row) => (
                <Row key={row.key} row={row} strings={strings} at={at} open={open} />
              ))}
            </Group>
          )}
          {buckets.queued.length > 0 && (
            <Group label={t("github.checks.queued")}>
              {buckets.queued.map((row) => (
                <Row key={row.key} row={row} strings={strings} at={at} open={open} />
              ))}
            </Group>
          )}
          {buckets.passed.length > 0 && (
            <div className="gh-check-group" data-check="passed">
              <button
                type="button"
                className="gh-fold"
                aria-expanded={showPassed}
                onClick={() => setShowPassed((shown) => !shown)}
              >
                <Chevron open={showPassed} />
                <span className="gh-dot" aria-hidden="true" />
                <span>{t("github.checks.passed")}</span>
                <span className="gh-count">{summary.passed}</span>
              </button>
              {showPassed && (
                <ul className="gh-list gh-ci-rows">
                  {buckets.passed.map((row) => (
                    <Row key={row.key} row={row} strings={strings} at={at} open={open} />
                  ))}
                </ul>
              )}
            </div>
          )}
        </>
      )}
    </section>
  );
}

function Group({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="gh-check-group">
      <div className="gh-check-group-title">{label}</div>
      <ul className="gh-list gh-ci-rows">{children}</ul>
    </div>
  );
}

/** One row: its state's dot, its name (a link to the job), its workflow, its shards' pips, its time. */
function Row({
  row,
  strings,
  at,
  open,
  children,
}: {
  row: DashboardRow;
  strings: Strings;
  at: number;
  open: (url: string) => void;
  children?: ReactNode;
}) {
  const first = row.jobs.find((job) => job.state === row.state) ?? row.jobs[0]!;
  const time = rowTime(row, at, strings);
  const dot = row.state === "running" ? "pending" : row.state;
  return (
    <li className="gh-ci-row" data-check={dot}>
      <div className="gh-ci-line">
        <span className="gh-dot" aria-hidden="true" />
        {first.url ? (
          <button type="button" className="gh-row-link" title={first.name} onClick={() => open(first.url!)}>
            {row.name}
          </button>
        ) : (
          <span className="gh-row-name">{row.name}</span>
        )}
        {row.workflow && <span className="gh-muted gh-ci-workflow">{row.workflow}</span>}
        {row.matrix && (
          <span className="gh-ci-pips">
            {row.jobs.map((job) => (
              <button
                key={job.id || job.name}
                type="button"
                className="gh-ci-pip"
                data-check={job.state === "running" ? "pending" : job.state}
                title={job.name}
                aria-label={job.name}
                onClick={() => job.url && open(job.url)}
              />
            ))}
          </span>
        )}
        {row.state === "failed" && row.jobs.some((job) => job.onBase) && (
          <span className="gh-muted gh-row-note">{strings.t("github.checks.onBase")}</span>
        )}
        {time && <span className="gh-ci-time">{time}</span>}
      </div>
      {children}
    </li>
  );
}

/** A running row's longest elapsed time (and what it usually takes); a finished one's duration. */
function rowTime(row: DashboardRow, at: number, strings: Strings): string | undefined {
  const jobs = row.state === "running" ? row.jobs.filter((job) => job.state === "running") : row.jobs;
  const seconds = Math.max(0, ...jobs.map((job) => elapsed(job, at)));
  if (!seconds) return undefined;
  const text = duration(seconds, strings.language);
  const expected = Math.max(0, ...jobs.map((job) => job.expected ?? 0));
  return row.state === "running" && expected
    ? strings.format("github.checks.usually", text, duration(expected, strings.language))
    : text;
}

/** A failed job's failing step and the end of its log, as the host read them. */
function Failure({ job, row, strings }: { job: DashboardJob; row: DashboardRow; strings: Strings }) {
  const step = job.failure?.step;
  const excerpt = job.failure?.excerpt;
  if (!step && !excerpt && !row.matrix) return null;
  return (
    <div className="gh-ci-failure">
      <div className="gh-ci-failure-head">
        {row.matrix && <span className="gh-ci-shard">{job.name}</span>}
        {step && <span>{strings.format("github.checks.step", step)}</span>}
      </div>
      {excerpt && <pre className="gh-ci-log">{excerpt}</pre>}
    </div>
  );
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      className="gh-chevron"
      data-open={open || undefined}
      width="12"
      height="12"
      viewBox="0 0 12 12"
      aria-hidden="true"
    >
      <path d="M4.5 2.5 8 6l-3.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
