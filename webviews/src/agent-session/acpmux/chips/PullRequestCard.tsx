// One pull request card for every pull request cmux mentions (Leo 2026-10-20): a chip in a reply,
// an inline link, the pull request bars above the composer. Leo saw a `#22777` chip show nothing
// but "github.com · https://github.com/.../pull/22777, Open", while the older, richer card said
// "GitHub rate limit · resets 9:11 PM" where the pull request should have been.
//
// The card reads: the pull request glyph in its state's colour beside the title (in the link card's
// head when it has one, cut to two lines) — open green, merged purple, closed red, draft grey —
// then the state and checks, the author and time, and a compact file and line summary. The link,
// branch names, review decision and labels stay secondary below that summary. The diff summary
// keeps each file kind inline, using the same classifier as the diff viewer (src/fileKinds.ts),
// rather than nesting another card inside the hover card.
//
// Nothing here calls GitHub. The host answers from its own cache and reads gh in the background
// (pullRequestStore.ts, AgentReplyPullRequests); when its answer is not fresh the card prints how
// old it is instead of an error.
import { useState, type CSSProperties, type ReactNode } from "react";
import { FILE_KINDS, kindTotals, missingTests, type FileKind } from "../../../fileKinds";
import { usePaneLanguage, useT, type PaneLanguage, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { Tooltip } from "../../../ui/Tooltip";
import { relativeTime } from "../conversation/relativeTime";
import { usePullRequestAnswer, type LinkedPullRequest } from "./pullRequestStore";
import { githubItemRef } from "./pullRequestCardModel";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { useLoadFade } from "../../shared/loadFade";

const BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  draft: "header.prBadge.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
};

/// An issue's states as GitHub words them: closed (completed) is "Closed", not planned its own.
const ISSUE_BADGES: Record<string, StringKey> = {
  open: "header.prBadge.open",
  closed: "header.prBadge.closed",
  not_planned: "prCard.issueNotPlanned",
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
  const item = githubItemRef(url);
  const link = item?.url;
  const plain = link ?? url;
  const answer = usePullRequestAnswer(plain, open);
  const read = answer?.pullRequest ?? undefined;
  // An issue (Leo 2026-11-08, of a private repo's issue whose card showed only its link): its
  // state, author and labels; it has no checks, files or branches.
  const issue = item?.kind === "issue" || read?.kind === "issue";
  const badges = issue ? ISSUE_BADGES : BADGES;
  // The host is still reading (or has not answered the card's own ask yet: no answer, or only the
  // chip's cache-only one): its rows are held at their size, so the card opens at about the size
  // it ends at and no row pops in under the pointer (Leo 2026-11-06). A reader that is never asked
  // (read only) or a host with nothing to say draws none.
  const readOnly = useTranscriptReadOnly();
  const waiting = !read && !readOnly && (answer === undefined || answer.reading || answer.cacheOnly === true);
  // The host's answer came after the card drew its placeholders: the rows it fills fade in once
  // (shared/loadFade.ts) instead of popping; a card drawn from a kept answer shows at once.
  const loadFade = useLoadFade(!waiting);
  // The swap is a crossfade in place (Leo 2026-11-08: "a bit too discontinuous and jumpy"): each
  // placeholder, drawn in the shape its row takes, shares one grid cell with the row it held
  // (`Slot`), fades out as the row fades in, and goes on its own animation's end. No timer.
  const leaving = loadFade && fadePlays();

  const title = read?.title || known.title;
  const state = read?.state || known.state;
  // What the placeholders held, so only those rows crossfade.
  const heldStatus = !known.state;
  const live = !issue && state !== "merged" && state !== "closed";
  const shown = {
    status: !!state || (live && (!!read?.checks || read?.mergeable === "conflicting")),
    who: !!read?.author,
    changes: hasChanges(read),
    branches: !!(read?.baseRef && read.headRef),
    labels: !!(read && ((read.review && REVIEWS[read.review]) || (read.labels?.length ?? 0) > 0)),
  };
  const now = Date.now();
  // A time the card cannot read is a line it leaves out, never a throw: `relativeTime` hands an
  // unparsed date to `Intl.DateTimeFormat`, which raises RangeError on NaN, and a raise in here
  // takes the whole card down over one string the host passed through from GitHub.
  const updatedAt = read?.updatedAt == null ? Number.NaN : Date.parse(read.updatedAt);
  const reference = `${known.repo}#${known.number}`;
  const glyph = (
    <span className="acpmux-pr-card__glyph" data-state={state || undefined} data-kind={issue ? "issue" : undefined}>
      {/* The state's word is the glyph's accessible name; the card also shows it in the status row. */}
      <Icon
        name={issue ? issueGlyph(state) : "git.pullrequest"}
        size={14}
        title={state && badges[state] ? t(badges[state]!) : undefined}
      />
    </span>
  );
  return (
    <>
      {head?.(title || reference, glyph)}
      <div className="acpmux-pr-card__body" data-load-fade={loadFade ? "" : undefined}>
        {!head && title && <div className="acpmux-pr-card__title">{title}</div>}
        <Slot hold={waiting && !state} leaving={leaving && heldStatus} shown={shown.status} row="status">
          <Status state={state} read={read} t={t} issue={issue} badges={badges} />
        </Slot>
        <Slot hold={waiting} leaving={leaving} shown={shown.who} row="who">
          {read?.author && (
            <div className="acpmux-pr-card__who">
              {read.authorAvatar?.startsWith("data:image/") ? (
                // The host's copy of their GitHub picture (Leo 2026-11-07: "can you not just also pull
                // the GitHub icon for the profile picture?"), in the monogram's own box, so the row
                // keeps its size whichever one shows.
                <img className="acpmux-pr-card__avatar" src={read.authorAvatar} alt="" width={18} height={18} />
              ) : (
                <Monogram login={read.author} />
              )}
              <span className="acpmux-pr-card__author">{read.author}</span>
              {Number.isFinite(updatedAt) && (
                <span className="acpmux-pr-card__when">
                  {t("prCard.updated", { ago: relativeTime(updatedAt, now, language) })}
                </span>
              )}
            </div>
          )}
        </Slot>
        {!issue && (
          <Slot hold={waiting} leaving={leaving} shown={shown.changes} row="changes">
            <Changes read={read} t={t} />
          </Slot>
        )}
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
        </div>
        {/* A pull request's last held row is its branches; an issue's, its labels. */}
        <Slot hold={waiting && !issue} leaving={leaving && !issue} shown={shown.branches} row="branches">
          <Branches read={read} />
        </Slot>
        <Slot hold={waiting && issue} leaving={leaving && issue} shown={shown.labels} row="labels">
          <Review read={read} t={t} />
        </Slot>
        <Freshness answer={answer} now={now} t={t} language={language} held={waiting} />
      </div>
    </>
  );
}

/// One row the host's answer fills, held at its height while the host reads: the row's own class
/// (so its line height and gaps are the real row's) around static muted bars, hidden from screen
/// readers (the "reading…" line says it). No shimmer: nothing moves while the card waits.
/// Whether the load fade plays here: with motion reduced or off there is no fade to end, so no
/// placeholder stays for one.
function fadePlays(): boolean {
  if (typeof document === "undefined") return false;
  const motion = document.documentElement.dataset;
  if ([motion.agentMotion, motion.cmuxMotion].some((value) => value === "off" || value === "reduced")) return false;
  return !globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
}

type PlaceholderRow = "status" | "who" | "changes" | "branches" | "labels";

function Placeholder({ row, onAnimationEnd }: { row: PlaceholderRow; onAnimationEnd?: () => void }) {
  const bar = (size: "s" | "m" | "l") => <span className="acpmux-pr-card__bar" data-size={size} />;
  switch (row) {
    case "status":
      return (
        <div
          className="acpmux-pr-card__status"
          data-placeholder={row}
          aria-hidden="true"
          onAnimationEnd={onAnimationEnd}
        >
          {bar("s")}
        </div>
      );
    case "who":
      return (
        <div className="acpmux-pr-card__who" data-placeholder={row} aria-hidden="true" onAnimationEnd={onAnimationEnd}>
          <span className="acpmux-pr-card__face" />
          {bar("m")}
        </div>
      );
    case "changes":
      return (
        // The answer's three lines: the counts, the bar by kind, and each kind's `+/−`.
        <div
          className="acpmux-pr-card__changes"
          data-placeholder={row}
          aria-hidden="true"
          onAnimationEnd={onAnimationEnd}
        >
          <div className="acpmux-pr-card__counts">{bar("s")}</div>
          <div className="acpmux-pr-card__kindBar" />
          <div className="acpmux-pr-card__breakdown">{bar("m")}</div>
        </div>
      );
    case "branches":
      return (
        <div
          className="acpmux-pr-card__branches"
          data-placeholder={row}
          aria-hidden="true"
          onAnimationEnd={onAnimationEnd}
        >
          {bar("l")}
        </div>
      );
    case "labels":
      return (
        <div
          className="acpmux-pr-card__review"
          data-placeholder={row}
          aria-hidden="true"
          onAnimationEnd={onAnimationEnd}
        >
          {bar("m")}
        </div>
      );
  }
}

/// The pack's issue glyph for `state`: open, closed (completed) or not planned.
function issueGlyph(state: string | undefined) {
  return state === "closed" ? "git.issue.closed" : state === "not_planned" ? "git.issue.notplanned" : "git.issue";
}

function Status({
  state,
  read,
  t,
  issue,
  badges,
}: {
  state: string | undefined;
  read: LinkedPullRequest | undefined;
  t: Translate;
  issue: boolean;
  badges: Record<string, StringKey>;
}) {
  const live = !issue && state !== "merged" && state !== "closed";
  const checks = live && read?.checks ? <Checks read={read} t={t} /> : null;
  if (!state && !checks && (!live || read?.mergeable !== "conflicting")) return null;
  return (
    <div className="acpmux-pr-card__status">
      {state && (
        <span className="acpmux-pr-card__state" data-state={state} data-kind={issue ? "issue" : undefined}>
          {badges[state] ? t(badges[state]!) : state}
        </span>
      )}
      {checks}
      {live && read?.mergeable === "conflicting" && (
        <span className="acpmux-pr-card__conflicts">{t("header.prConflicts")}</span>
      )}
    </div>
  );
}

/// One row the host's answer fills. While `hold`, its placeholder; once the answer lands, the row,
/// and while `leaving` (the load fade, shared/loadFade.ts) the placeholder too, in the same grid
/// cell, fading out as the row fades in (linkCard.css `__slot`): nothing moves, and the cell is
/// already the row's size, so nothing moves when the placeholder goes either. A row the answer
/// leaves empty drops its placeholder at once, in the frame the answer lands.
///
/// Each slot goes on its own placeholder's animation end, so a row that starts later keeps its
/// whole crossfade (review of #38163, F1). The wrapper stays once the row shows: dropping it would
/// remount the row and restart its fade from nothing. An empty wrapper takes no space
/// (linkCard.css `__slot:empty`).
function Slot({
  hold,
  leaving,
  shown,
  row,
  children,
}: {
  hold: boolean;
  leaving: boolean;
  /// The row draws something once the answer lands.
  shown: boolean;
  row: PlaceholderRow;
  children: ReactNode;
}) {
  const [faded, setFaded] = useState(false);
  if (hold) return <Placeholder row={row} />;
  return (
    // The row first, so the placeholder draws over it as it fades out.
    <div className="acpmux-pr-card__slot">
      {children}
      {leaving && shown && !faded && <Placeholder row={row} onAnimationEnd={() => setFaded(true)} />}
    </div>
  );
}

function Branches({ read }: { read: LinkedPullRequest | undefined }) {
  if (!read?.baseRef || !read.headRef) return null;
  return (
    <div className="acpmux-pr-card__branches">
      <span className="acpmux-pr-card__branch">{read.baseRef}</span>
      <span aria-hidden="true">←</span>
      <span className="acpmux-pr-card__branch">{read.headRef}</span>
    </div>
  );
}

/// An open pull request's CI checks, said in words (Leo 2026-11-07: "The check mark, the X mark,
/// whatever. What does that mean? Is that the tests or what? As in, like the CI?"): "Checks 11
/// passed · 1 failed · 1 running", and how many of the failures the base branch's tip has too — a
/// red the pull request did not cause, which is what decides whether anyone has to go and look at
/// it. The host works that out (AgentPanePullRequest `failingOnBase`, which only compares each
/// workflow's newest run, so a run the concurrency group cancelled can never excuse a red); the card
/// only reads it. Pointing at the row lists the failing and running checks by name. The whole
/// sentence is for screen readers; the row is for the eye.
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
  const failingNames = rows.filter((check) => check.state === "failed").map((check) => check.name);
  const runningNames = rows.filter((check) => check.state === "pending").map((check) => check.name);
  const row = (
    <div
      className="acpmux-pr-card__checks"
      data-state={checks.state}
      // Every red is base's: the failures read muted rather than danger, because nothing here is
      // this pull request's to fix (the merge rules say so too).
      data-on-base={onBase > 0 && onBase >= failing ? "all" : undefined}
      // Focusable only when it has names to show, so a keyboard reaches the same list a pointer does.
      // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- the check names' tooltip is keyboard-focusable without an action
      tabIndex={failingNames.length + runningNames.length > 0 ? 0 : undefined}
    >
      <span className="acpmux-pr-card__sr">{sentence}</span>
      <span className="acpmux-pr-card__checksName" aria-hidden="true">
        {t("prCard.checksName")}
      </span>
      <span className="acpmux-pr-card__passed" aria-hidden="true">
        <span className="acpmux-pr-card__count">{checks.passed}</span> {t("prCard.checksPassed")}
      </span>
      {failing > 0 && (
        <span className="acpmux-pr-card__failed" aria-hidden="true">
          <span className="acpmux-pr-card__count">{failing}</span> {t("prCard.checksFailed")}
        </span>
      )}
      {onBase > 0 && (
        <span className="acpmux-pr-card__onBase" aria-hidden="true">
          {t("sessionInfo.changes.failingOnBase", { count: onBase })}
        </span>
      )}
      {pending > 0 && (
        <span className="acpmux-pr-card__pending" aria-hidden="true">
          <span className="acpmux-pr-card__count">{pending}</span> {t("prCard.checksRunning")}
        </span>
      )}
    </div>
  );
  if (failingNames.length + runningNames.length === 0) return row;
  return (
    <Tooltip
      className="ui-card acpmux-pr-card__checkNames"
      side="bottom"
      label={
        <>
          <CheckNames title={t("prCard.checksFailingNames")} names={failingNames} state="failed" />
          <CheckNames title={t("prCard.checksRunningNames")} names={runningNames} state="pending" />
        </>
      }
    >
      {row}
    </Tooltip>
  );
}

/// How many check names a list shows before it stops with "…": the host keeps at most 50, and a
/// tooltip that long is a page.
const NAMES_SHOWN = 8;

function CheckNames({ title, names, state }: { title: string; names: string[]; state: "failed" | "pending" }) {
  if (names.length === 0) return null;
  return (
    <div className="acpmux-pr-card__checkList" data-state={state}>
      <div className="acpmux-pr-card__checkListTitle">{title}</div>
      {names.slice(0, NAMES_SHOWN).map((name, index) => (
        <div key={`${index}:${name}`} className="acpmux-pr-card__checkName">
          {name}
        </div>
      ))}
      {names.length > NAMES_SHOWN && <div className="acpmux-pr-card__checkName">…</div>}
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
        <Label key={name} name={name} color={read?.labelColors?.[name]} />
      ))}
    </div>
  );
}

const HEX_COLOR = /^[0-9a-f]{6}$/i;

/// How many tones a label without GitHub's colour picks from (linkCard.css `__label[data-tone]`).
const LABEL_TONES = 8;

/// A label in its GitHub colour (Leo 2026-11-07: "Are we able to pull the colors? Or at least ...
/// just have some colors"), drawn as a tint with the colour mixed into the text so a pale or a dark
/// label reads in both themes. One GitHub has no colour for gets a tone its name picks, and a
/// `risk:high` without one is drawn in the failure ink, never as a grey chip.
function Label({ name, color }: { name: string; color: string | undefined }) {
  if (color && HEX_COLOR.test(color))
    return (
      <span className="acpmux-pr-card__label" data-colored="" style={{ "--label": `#${color}` } as CSSProperties}>
        {name}
      </span>
    );
  return (
    <span className="acpmux-pr-card__label" data-tone={name === "risk:high" ? "danger" : toneOf(name, LABEL_TONES)}>
      {name}
    </span>
  );
}

/// A stable tone for `text`: the same name gets the same tone in every card.
function toneOf(text: string, tones: number): number {
  let hash = 0;
  for (const character of text) hash = (hash * 31 + character.codePointAt(0)!) % 4096;
  return hash % tones;
}

/// The files and `+/−`, then one bar split by how many lines each kind of file changed (code, tests,
/// generated, ... — the diff viewer's classifier, src/fileKinds.ts) with each kind's `+/−` under
/// it (Leo 2026-11-07: "as for the code, the test, the generated files, and whatever, could we do
/// that better?"). When GitHub listed only some of the files (it sends the first 100), the numbers
/// say so beside them: "from 100 of 255 files".
/// Whether the answer has a files and lines row to draw (``Changes``).
function hasChanges(read: LinkedPullRequest | undefined): boolean {
  if (!read) return false;
  return (read.changedFiles || read.files?.length || 0) > 0 || (read.additions ?? 0) > 0 || (read.deletions ?? 0) > 0;
}

function Changes({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  if (!hasChanges(read) || !read) return null;
  const files = read.files ?? [];
  const changed = read.changedFiles || files.length;
  const additions = read.additions ?? 0;
  const deletions = read.deletions ?? 0;
  if (changed === 0 && additions === 0 && deletions === 0) return null;
  const totals = kindTotals(files);
  const noTests = files.length > 0 && files.length === changed && missingTests(files);
  const partial = files.length > 0 && files.length < changed;
  const kinds = FILE_KINDS.flatMap((kind) => totals.filter((total) => total.kind === kind));
  const lines = kinds.reduce((sum, total) => sum + total.additions + total.deletions, 0);
  return (
    <div className="acpmux-pr-card__changes">
      <div className="acpmux-pr-card__counts">
        {changed > 0 && <span className="acpmux-pr-card__files">{t("prCard.files", { n: changed })}</span>}
        <span className="acpmux-pr-card__lines" aria-label={t("prCard.linesByKind")}>
          <span className="acpmux-pr-card__added">+{additions.toLocaleString()}</span>
          <span className="acpmux-pr-card__removed">−{deletions.toLocaleString()}</span>
        </span>
        {noTests && <span className="acpmux-pr-card__warning">{t("prCard.noTests")}</span>}
      </div>
      {kinds.length > 0 && (
        <>
          {lines > 0 && (
            <div className="acpmux-pr-card__kindBar" aria-hidden="true">
              {kinds.map((total) => {
                const share = (total.additions + total.deletions) / lines;
                return share > 0 ? (
                  <span
                    key={total.kind}
                    className="acpmux-pr-card__barPart"
                    data-kind={total.kind}
                    style={{ flexGrow: share }}
                  />
                ) : null;
              })}
            </div>
          )}
          <div className="acpmux-pr-card__breakdown" aria-label={t("prCard.linesByKind")}>
            {kinds.map((total) => (
              <span key={total.kind} className="acpmux-pr-card__kind" data-kind={total.kind}>
                <span className="acpmux-pr-card__kindDot" aria-hidden="true" />
                <span className="acpmux-pr-card__kindName">{t(KINDS[total.kind])}</span>
                <span className="acpmux-pr-card__added">+{total.additions.toLocaleString()}</span>
                {total.deletions > 0 && (
                  <span className="acpmux-pr-card__removed">−{total.deletions.toLocaleString()}</span>
                )}
              </span>
            ))}
            {partial && (
              <span className="acpmux-pr-card__kindPartial">
                {t("prCard.kindsFrom", { shown: files.length, total: changed })}
              </span>
            )}
          </div>
        </>
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
  held,
}: {
  answer: { fetchedAt?: number; reading: boolean } | undefined;
  now: number;
  t: Translate;
  language: PaneLanguage;
  /// The placeholders hold the card's rows: "reading…" is for screen readers only, so no line
  /// shows and then goes when the answer lands.
  held?: boolean;
}) {
  if (!answer) return null;
  if (held) return answer.reading ? <div className="acpmux-pr-card__sr">{t("prCard.reading")}</div> : null;
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

/// The author's monogram, until the host has their GitHub picture (or when it never will: offline,
/// a GitHub Enterprise host): their first letter on a tone their login picks out of the theme's
/// palette.
function Monogram({ login }: { login: string }) {
  const first = login.codePointAt(0);
  const letter = first == null ? "?" : String.fromCodePoint(first).toUpperCase();
  return (
    <span className="acpmux-pr-card__monogram" data-tone={toneOf(login, MONOGRAM_TONES)} aria-hidden="true">
      {letter}
    </span>
  );
}
