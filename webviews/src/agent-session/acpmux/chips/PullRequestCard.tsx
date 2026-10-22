// One pull request card for every pull request cmux mentions (Leo 2026-10-20): a chip in a reply,
// an inline link, the pull request bars above the composer. Leo saw a `#22777` chip show nothing
// but "github.com · https://github.com/.../pull/22777, Open", while the older, richer card said
// "GitHub rate limit · resets 9:11 PM" where the pull request should have been.
//
// The card reads: the pull request glyph in its state's colour beside the title (in the link card's
// head when it has one, cut to two lines) — open green, merged purple, closed red, draft grey, as
// Claude draws it, with no state word (Leo 2026-10-21) — then `owner/repo#N` (its link, blue like
// every link), conflicts, the author with a monogram and when GitHub last saw it change,
// `base ← head`, an open pull request's checks as a compact ✓/✗ count (a merged or closed one's no
// longer matter), with how many reds are also red on base (when every one is, the ✗ reads muted,
// not as this pull request's), the review decision and labels, and the files with `+/−`.
// Hovering (or focusing) the `+/−` breaks those lines down by kind — Code, Tests, Mocks, Docs,
// Evals, Generated — from the one classifier the diff viewer groups by (src/fileKinds.ts), and
// says so when code changed with no test.
//
// Nothing here calls GitHub. The host answers from its own cache and reads gh in the background
// (pullRequestStore.ts, AgentReplyPullRequests); when its answer is not fresh the card prints how
// old it is instead of an error.
import { useState, type ReactNode } from "react";
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
/// `head` draws the caller's head row around the title and the state glyph (LinkHoverCard: glyph,
/// title, Open, Open in); without it the glyph leads the body's first row, under the title.
export function PullRequestCardBody({
  url,
  known,
  open,
  head,
}: {
  url: string;
  known: KnownPullRequest;
  open: boolean;
  head?: (title: string, glyph: ReactNode) => ReactNode;
}) {
  const t = useT();
  // Every age in the card is worded in the pane's own language, like a message's time
  // (UserBubble): without it Intl falls back to the host's ICU default and a Japanese pane reads
  // "vor 3 Minuten".
  const language = usePaneLanguage();
  const link = pullRequestRef(url)?.url;
  const plain = link ?? url;
  const answer = usePullRequestAnswer(plain, open);
  const read = answer?.pullRequest ?? undefined;
  const title = read?.title || known.title;
  const state = read?.state || known.state;
  const now = Date.now();
  // A time the card cannot read is a line it leaves out, never a throw: `relativeTime` hands an
  // unparsed date to `Intl.DateTimeFormat`, which raises RangeError on NaN, and a raise in here
  // takes the whole card down over one string the host passed through from GitHub.
  const updatedAt = read?.updatedAt == null ? Number.NaN : Date.parse(read.updatedAt);
  const reference = `${known.repo}#${known.number}`;
  const glyph = (
    <span className="acpmux-pr-card__glyph" data-state={state || undefined}>
      {/* The state's word is the glyph's accessible name only; the card shows its colour. */}
      <Icon name="git.pullrequest" size={14} title={state && BADGES[state] ? t(BADGES[state]!) : undefined} />
    </span>
  );
  return (
    <>
      {head?.(title || reference, glyph)}
      <div className="acpmux-pr-card__body">
        {!head && title && <div className="acpmux-pr-card__title">{title}</div>}
        <div className="acpmux-pr-card__facts">
          {!head && glyph}
          {/* The pull request's link, styled as one (Leo 2026-10-20: "the hovers need to be
              styled"); a click takes the host's link-click path, as the bar's and chip's anchors
              do. Only a parsed pull request address becomes a link; anything else stays text. */}
          {link ? (
            <a className="acpmux-pr-card__ref" href={link} rel="noreferrer">
              {reference}
            </a>
          ) : (
            <span className="acpmux-pr-card__ref">{reference}</span>
          )}
          {read?.mergeable === "conflicting" && state !== "merged" && state !== "closed" && (
            <span className="acpmux-pr-card__conflicts">{t("header.prConflicts")}</span>
          )}
          {read?.author && (
            <span className="acpmux-pr-card__who">
              <Monogram login={read.author} />
              <span className="acpmux-pr-card__author">{read.author}</span>
              {Number.isFinite(updatedAt) && (
                <span className="acpmux-pr-card__when">
                  {t("prCard.updated", { ago: relativeTime(updatedAt, now, language) })}
                </span>
              )}
            </span>
          )}
        </div>
        {read?.baseRef && read.headRef && (
          <div className="acpmux-pr-card__branches">
            <span className="acpmux-pr-card__branch">{read.baseRef}</span>
            <span aria-hidden="true">←</span>
            <span className="acpmux-pr-card__branch">{read.headRef}</span>
          </div>
        )}
        {state !== "merged" && state !== "closed" && <Checks read={read} t={t} />}
        <Review read={read} t={t} />
        <Changes read={read} t={t} />
        <Freshness answer={answer} now={now} t={t} language={language} />
      </div>
    </>
  );
}

/// An open pull request's checks, compact: ✓ passed, ✗ failing, ◷ still running, and how many of
/// the failures the base branch's tip has too — a red the pull request did not cause, which is
/// what decides whether anyone has to go and look at it. The host works that out
/// (AgentPanePullRequest `failingOnBase`, which only compares each workflow's newest run, so a run
/// the concurrency group cancelled can never excuse a red); the card only reads it. The whole
/// sentence is for screen readers; the glyphs are for the eye.
function Checks({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  const checks = read?.checks;
  if (!checks) return null;
  if (checks.total === 0) return <div className="acpmux-pr-card__checks">{t("header.prNoChecks")}</div>;
  const rows = read?.checkList ?? [];
  const failed = rows.filter((check) => check.state === "failed").length || 0;
  const failing = failed > 0 || checks.state === "failing" ? failed || checks.total - checks.passed : 0;
  const pending = Math.max(0, checks.total - checks.passed - failing);
  // The host's own count, because it counts the whole rollup while `checkList` is truncated; the
  // rows are the fallback for a host that marks them without counting them. Clamped, so the line
  // stays arithmetically honest whatever the two halves say.
  const marked = rows.filter((check) => check.state === "failed" && check.onBase === true).length;
  const onBase = Math.min(checks.failingOnBase ?? marked, failing);
  const counts = { passed: checks.passed, total: checks.total, failed: failing };
  const sentence =
    failing > 0
      ? onBase > 0
        ? t("prCard.checksFailingOnBase", { ...counts, onBase })
        : t("prCard.checksFailing", counts)
      : t("prCard.checks", counts);
  return (
    <div
      className="acpmux-pr-card__checks"
      data-state={checks.state}
      // Every red is base's: the ✗ reads muted rather than danger, because nothing here is this
      // pull request's to fix (the merge rules say so too).
      data-on-base={onBase > 0 && onBase >= failing ? "all" : undefined}
    >
      <span className="acpmux-pr-card__sr">{sentence}</span>
      <span className="acpmux-pr-card__passed" aria-hidden="true">
        ✓ {checks.passed}
      </span>
      {failing > 0 && (
        <span className="acpmux-pr-card__failed" aria-hidden="true">
          ✗ {failing}
        </span>
      )}
      {onBase > 0 && (
        <span className="acpmux-pr-card__onBase" aria-hidden="true">
          {t("chatInspector.changes.failingOnBase", { count: onBase })}
        </span>
      )}
      {pending > 0 && (
        <span className="acpmux-pr-card__pending" aria-hidden="true">
          ◷ {pending}
        </span>
      )}
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
