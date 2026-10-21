// One pull request card for every pull request cmux mentions (Leo 2026-10-20): a chip in a reply,
// an inline link, the pull request bars above the composer. Leo saw a `#22777` chip show nothing
// but "github.com · https://github.com/.../pull/22777, Open", while the older, richer card said
// "GitHub rate limit · resets 9:11 PM" where the pull request should have been.
//
// The card reads: the state pill (draft, open, merged, closed, and conflicts beside it),
// `owner/repo#N`, the title, the author with a monogram, when GitHub last saw it change,
// `base ← head`, the checks summed, the review decision and labels, and the files with `+/−`.
// Hovering (or focusing) the `+/−` breaks those lines down by kind — Code, Tests, Mocks, Docs,
// Evals, Generated — from the one classifier the diff viewer groups by (src/fileKinds.ts), and
// says so when code changed with no test.
//
// Nothing here calls GitHub. The host answers from its own cache and reads gh in the background
// (pullRequestStore.ts, AgentReplyPullRequests); when its answer is not fresh the card prints how
// old it is instead of an error.
import { useState } from "react";
import { FILE_KINDS, kindTotals, missingTests, type FileKind } from "../../../fileKinds";
import { usePaneLanguage, useT, type PaneLanguage, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { relativeTime } from "../conversation/relativeTime";
import { usePullRequestAnswer, type LinkedPullRequest } from "./pullRequestStore";

const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};

const REVIEWS: Record<string, StringKey> = {
  approved: "header.prReview.approved",
  changes_requested: "header.prReview.changesRequested",
  review_required: "header.prReview.required",
};

const KINDS: Record<FileKind, StringKey> = {
  code: "prCard.kind.code",
  tests: "prCard.kind.tests",
  mocks: "prCard.kind.mocks",
  docs: "prCard.kind.docs",
  evals: "prCard.kind.evals",
  generated: "prCard.kind.generated",
};

/// An answer older than this is worth saying the age of; a fresh one needs no apology.
const STALE_MS = 90_000;

// The host's own rule (AgentPaneReplyRequest.pullRequestURL): owner/repo, `pull`, the number, and
// at most one tab of it (`/files`); a query or a fragment is dropped before asking.
const PULL_REQUEST =
  /^https:\/\/github\.com\/([A-Za-z0-9_][\w.-]*\/[A-Za-z0-9_][\w.-]*)\/pull\/([1-9]\d{0,9})(?:\/[a-z]{1,20})?\/?(?:[?#].*)?$/i;

/// `owner/repo`, the number and the plain address of a GitHub pull request link, else undefined.
export function pullRequestRef(href: string): { repo: string; number: number; url: string } | undefined {
  const match = PULL_REQUEST.exec(href);
  if (!match) return undefined;
  return { repo: match[1]!, number: Number(match[2]), url: `https://github.com/${match[1]}/pull/${match[2]}` };
}

/// What the page knows before the host answers: the bar's or chip's own text.
export type KnownPullRequest = { repo: string; number: number; title?: string; state?: string };

/// The card's content; its frame (AnchoredCard) belongs to the caller. `open` asks the host.
export function PullRequestCardBody({ url, known, open }: { url: string; known: KnownPullRequest; open: boolean }) {
  const t = useT();
  // Every age in the card is worded in the pane's own language, like a message's time
  // (UserBubble): without it Intl falls back to the host's ICU default and a Japanese pane reads
  // "vor 3 Minuten".
  const language = usePaneLanguage();
  const plain = pullRequestRef(url)?.url ?? url;
  const answer = usePullRequestAnswer(plain, open);
  const read = answer?.pullRequest ?? undefined;
  const title = read?.title || known.title;
  const state = read?.state || known.state;
  const now = Date.now();
  // A time the card cannot read is a line it leaves out, never a throw: `relativeTime` hands an
  // unparsed date to `Intl.DateTimeFormat`, which raises RangeError on NaN, and a raise in here
  // takes the whole card down over one string the host passed through from GitHub.
  const updatedAt = read?.updatedAt == null ? Number.NaN : Date.parse(read.updatedAt);
  return (
    <div className="acpmux-pr-card__body">
      <div className="acpmux-pr-card__facts">
        <Icon name="git.pullrequest" size={13} />
        {state && (
          <span className="acpmux-pr-card__state" data-state={state}>
            {BADGES[state] ? t(BADGES[state]!) : state}
          </span>
        )}
        {read?.mergeable === "conflicting" && (
          <span className="acpmux-pr-card__state" data-state="conflicts">
            {t("header.prConflicts")}
          </span>
        )}
        <span className="acpmux-pr-card__ref">
          {known.repo}#{known.number}
        </span>
      </div>
      {title && <div className="acpmux-pr-card__title">{title}</div>}
      {read?.author && (
        <div className="acpmux-pr-card__who">
          <Monogram login={read.author} />
          <span className="acpmux-pr-card__author">{read.author}</span>
          {Number.isFinite(updatedAt) && (
            <span className="acpmux-pr-card__when">
              {t("prCard.updated", { ago: relativeTime(updatedAt, now, language) })}
            </span>
          )}
        </div>
      )}
      {read?.baseRef && read.headRef && (
        <div className="acpmux-pr-card__branches">
          <span className="acpmux-pr-card__branch">{read.baseRef}</span>
          <span aria-hidden="true">←</span>
          <span className="acpmux-pr-card__branch">{read.headRef}</span>
        </div>
      )}
      <Checks read={read} t={t} />
      <Review read={read} t={t} />
      <Changes read={read} t={t} />
      <Freshness answer={answer} now={now} t={t} language={language} />
    </div>
  );
}

/// The checks summed: how many passed, how many are failing, and how many of those failures the
/// base branch's tip has too — a red the pull request did not cause, which is what decides whether
/// anyone has to go and look at it. The host works that out (AgentPanePullRequest `failingOnBase`,
/// which only compares each workflow's newest run, so a run the concurrency group cancelled can
/// never excuse a red); the card only reads it.
function Checks({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  const checks = read?.checks;
  if (!checks) return null;
  if (checks.total === 0) return <div className="acpmux-pr-card__checks">{t("header.prNoChecks")}</div>;
  const rows = read?.checkList ?? [];
  const failed = rows.filter((check) => check.state === "failed").length || 0;
  const failing = failed || checks.total - checks.passed;
  // The rows carry the same truth per check, so either half of a host's answer is enough; the
  // clamp keeps the line arithmetic honest when `failing` fell back to the summed difference.
  const marked = rows.filter((check) => check.state === "failed" && check.onBase === true).length;
  const onBase = Math.min(Math.max(marked, checks.failingOnBase ?? 0), failing);
  return (
    <div
      className="acpmux-pr-card__checks"
      data-state={checks.state}
      // Every red is base's: the dot drops from danger to warning, because nothing here is this
      // pull request's to fix (the merge rules say so too).
      data-on-base={onBase > 0 && onBase >= failing ? "all" : undefined}
    >
      {failed > 0 || checks.state === "failing"
        ? onBase > 0
          ? t("prCard.checksFailingOnBase", {
              passed: checks.passed,
              total: checks.total,
              failed: failing,
              onBase,
            })
          : t("prCard.checksFailing", { passed: checks.passed, total: checks.total, failed: failing })
        : t("prCard.checks", { passed: checks.passed, total: checks.total })}
    </div>
  );
}

/// The review decision and the labels, on one line.
function Review({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  const review = read?.review ? REVIEWS[read.review] : undefined;
  const labels = read?.labels ?? [];
  if (!review && labels.length === 0) return null;
  return (
    <div className="acpmux-pr-card__review">
      {review && (
        <span className="acpmux-pr-card__decision" data-review={read!.review}>
          {t(review)}
        </span>
      )}
      {labels.map((name) => (
        <span key={name} className="acpmux-pr-card__label">
          {name}
        </span>
      ))}
    </div>
  );
}

/// The files and `+/−`; hovering or focusing them breaks the lines down by kind, and a click
/// pins that open so the breakdown can be read without holding the pointer still.
function Changes({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  const [hovered, setHovered] = useState(false);
  const [pinned, setPinned] = useState(false);
  const open = hovered || pinned;
  if (!read) return null;
  const files = read.files ?? [];
  const changed = read.changedFiles || files.length;
  const additions = read.additions ?? 0;
  const deletions = read.deletions ?? 0;
  if (changed === 0 && additions === 0 && deletions === 0) return null;
  const totals = kindTotals(files);
  const noTests = files.length > 0 && files.length === changed && missingTests(files);
  const partial = files.length > 0 && files.length < changed;
  return (
    <div className="acpmux-pr-card__changes">
      <div className="acpmux-pr-card__counts">
        {changed > 0 && <span className="acpmux-pr-card__files">{t("prCard.files", { n: changed })}</span>}
        <button
          type="button"
          className="acpmux-pr-card__lines"
          aria-expanded={totals.length > 0 ? open : undefined}
          disabled={totals.length === 0}
          onPointerEnter={() => setHovered(true)}
          onPointerLeave={() => setHovered(false)}
          onFocus={() => setHovered(true)}
          onBlur={() => setHovered(false)}
          onClick={() => setPinned((was) => !was)}
        >
          <span className="acpmux-pr-card__added">+{additions.toLocaleString()}</span>
          <span className="acpmux-pr-card__removed">−{deletions.toLocaleString()}</span>
        </button>
        {/* Why, on the line below rather than in a `title`: this card is what replaces system
            tooltips, so it does not grow one of its own. */}
        {noTests && <span className="acpmux-pr-card__warning">{t("prCard.noTests")}</span>}
      </div>
      {open && totals.length > 0 && (
        <ul className="acpmux-pr-card__kinds" aria-label={t("prCard.linesByKind")}>
          {FILE_KINDS.filter((kind) => totals.some((total) => total.kind === kind)).map((kind) => {
            const total = totals.find((entry) => entry.kind === kind)!;
            return (
              <li key={kind} className="acpmux-pr-card__kind" data-kind={kind}>
                <span className="acpmux-pr-card__kindName">{t(KINDS[kind])}</span>
                <span className="acpmux-pr-card__added">+{total.additions.toLocaleString()}</span>
                <span className="acpmux-pr-card__removed">−{total.deletions.toLocaleString()}</span>
              </li>
            );
          })}
          {noTests && <li className="acpmux-pr-card__kindPartial">{t("prCard.noTestsWhy")}</li>}
          {partial && (
            <li className="acpmux-pr-card__kindPartial">{t("prCard.kindsPartial", { shown: files.length })}</li>
          )}
        </ul>
      )}
    </div>
  );
}

/// How old the host's answer is. A fresh one says nothing; a stale one says its age instead of
/// letting the card look current, and a running read says so.
function Freshness({
  answer,
  now,
  t,
  language,
}: {
  answer: { fetchedAt?: number; reading: boolean } | undefined;
  now: number;
  t: Translate;
  language: PaneLanguage;
}) {
  if (!answer) return null;
  const at = Number.isFinite(answer.fetchedAt) ? answer.fetchedAt! * 1000 : undefined;
  // Nothing read and nothing being read: the host has no answer and is not going to have one
  // soon (no gh on the PATH, or a pull request this account cannot see — it waits `retry` before
  // trying again). Saying "reading…" there is a lie that never resolves, so the card shows only
  // what the reply itself knows.
  if (at == null) return answer.reading ? <div className="acpmux-pr-card__age">{t("prCard.reading")}</div> : null;
  if (now - at < STALE_MS && !answer.reading) return null;
  return <div className="acpmux-pr-card__age">{t("prCard.read", { ago: relativeTime(at, now, language) })}</div>;
}

/// How many tones a monogram picks from; each is one of the theme's own terminal colours.
const MONOGRAM_TONES = 6;

/// The author's monogram: their first letter on a tone their login picks out of the theme's
/// palette. cmux draws no avatar it would have to fetch from GitHub, so a card costs no network,
/// leaks nothing to github.com, and looks the same offline.
function Monogram({ login }: { login: string }) {
  const first = login.codePointAt(0);
  const letter = first == null ? "?" : String.fromCodePoint(first).toUpperCase();
  let hash = 0;
  for (const character of login) hash = (hash * 31 + character.codePointAt(0)!) % 4096;
  return (
    <span className="acpmux-pr-card__monogram" data-tone={hash % MONOGRAM_TONES} aria-hidden="true">
      {letter}
    </span>
  );
}
