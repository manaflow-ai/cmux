// One pull request card for every pull request cmux mentions (Leo 2026-10-20): a chip in a reply,
// an inline link, the pull request bars above the composer.
//
// The card reads: the pull request glyph in its state's colour beside the title (in the link card's
// head when it has one, cut to two lines) — open green, merged purple, closed red, draft grey —
// then the author/time left-aligned on the icon's rail with review & labels on the right, CI checks
// (with an inline expandable failure list) and a compact file and line summary, and finally the blue
// owner/repo#N link paired directly above the branch names.
//
// Nothing here calls GitHub. The host answers from its own cache and reads gh in the background
// (pullRequestStore.ts, AgentReplyPullRequests); when its answer is not fresh the card prints how
// old it is instead of an error.
import { useState, type CSSProperties, type ReactNode } from "react";
import { FILE_KINDS, kindTotals, type FileKind } from "../../../fileKinds";
import { usePaneLanguage, useT, type PaneLanguage, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { Button } from "../../../ui/Button";
import { CopyButton } from "../conversation/CopyButton";
import { relativeTime } from "../conversation/relativeTime";
import { usePullRequestAnswer, type LinkedPullRequest } from "./pullRequestStore";
import { githubItemRef } from "./pullRequestCardModel";
import { repeatsTitle } from "./linkHoverCardModel";
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
  generated: "prCard.kind.generatedFiles",
};

/// An answer older than this is worth saying the age of; a fresh one needs no apology.
/// Matches AgentReplyPullRequests: open PRs refresh after 60 s (90 s grace here), while merged or
/// closed PRs stay fresh for an hour so settled cards never show a noisy "synced 9 minutes ago".
const STALE_MS = 90_000;
const SETTLED_STALE_MS = 3_600_000;

/// What the page knows before the host answers: the bar's or chip's own text.
export type KnownPullRequest = { repo: string; number: number; title?: string; state?: string };

/// The card's content; its frame (AnchoredCard) belongs to the caller. `open` asks the host.
/// `head` draws the caller's head row around the title and the state glyph (LinkHoverCard: glyph,
/// title, Review, Open, Open in); without it the glyph leads the title row in the body.
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
  const readOnly = useTranscriptReadOnly();
  const waiting = !read && !readOnly && (answer === undefined || answer.reading || answer.cacheOnly === true);
  const loadFade = useLoadFade(!waiting);
  const leaving = loadFade && fadePlays();

  const title = read?.title || known.title;
  const state = read?.state || known.state;
  const heldStatus = !issue && known.state !== "merged" && known.state !== "closed";
  const live = !issue && state !== "merged" && state !== "closed";
  const shown = {
    status: live && (!!read?.checks || read?.mergeable === "conflicting"),
    who: !!read?.author,
    changes: hasChanges(read),
    branches: !!(read?.baseRef && read.headRef),
    labels: !!(read && ((read.review && REVIEWS[read.review]) || (read.labels?.length ?? 0) > 0)),
  };
  const now = Date.now();
  const updatedAt = read?.updatedAt == null ? Number.NaN : Date.parse(read.updatedAt);
  const reference = `${known.repo}#${known.number}`;
  const showReference = !head || !repeatsTitle(title || reference, reference);
  const glyph = (
    <span className="acpmux-pr-card__glyph" data-state={state || undefined} data-kind={issue ? "issue" : undefined}>
      <Icon
        name={issue ? issueGlyph(state) : prGlyph(state)}
        size={14}
        title={state && badges[state] ? t(badges[state]!) : undefined}
      />
    </span>
  );
  const showByline = waiting || shown.who || shown.labels;
  const showProvenance = showReference || (!issue && (waiting || shown.branches));
  return (
    <>
      {head?.(title || reference, glyph)}
      <div className="acpmux-pr-card__body" data-load-fade={loadFade ? "" : undefined}>
        {!head && title && (
          <div className="acpmux-pr-card__titleRow">
            {glyph}
            <div className="acpmux-pr-card__title">{title}</div>
          </div>
        )}
        {showByline && (
          <div className="acpmux-pr-card__byline">
            <Slot hold={waiting} leaving={leaving} shown={shown.who} row="who">
              {read?.author && (
                <div className="acpmux-pr-card__who">
                  {read.authorAvatar?.startsWith("data:image/") ? (
                    <img className="acpmux-pr-card__avatar" src={read.authorAvatar} alt="" width={16} height={16} />
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
            <Slot hold={waiting && issue} leaving={leaving && issue} shown={shown.labels} row="labels">
              <Review read={read} t={t} />
            </Slot>
          </div>
        )}
        {!issue && (
          <Slot hold={waiting && live} leaving={leaving && heldStatus} shown={shown.status} row="status">
            <Status state={state} read={read} t={t} issue={issue} />
          </Slot>
        )}
        {!issue && (
          <Slot hold={waiting} leaving={leaving} shown={shown.changes} row="changes">
            <Changes read={read} t={t} />
          </Slot>
        )}
        {showProvenance && (
          <div className="acpmux-pr-card__provenance">
            {showReference && (
              <div className="acpmux-pr-card__facts">
                {!head && !title && glyph}
                {link ? (
                  <>
                    <a className="acpmux-pr-card__ref" href={link} rel="noreferrer">
                      {reference}
                    </a>
                    <CopyButton text={link} label={t("turn.copy")} className="acpmux-pr-card__copyBtn" size={12} />
                  </>
                ) : (
                  <span className="acpmux-pr-card__ref">{reference}</span>
                )}
              </div>
            )}
            <Slot hold={waiting && !issue} leaving={leaving && !issue} shown={shown.branches} row="branches">
              <Branches read={read} t={t} />
            </Slot>
          </div>
        )}
        <Freshness
          answer={answer}
          now={now}
          t={t}
          language={language}
          held={waiting}
          settled={state === "merged" || state === "closed" || state === "not_planned"}
        />
      </div>
    </>
  );
}

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

/// The pack's pull request glyph for `state`: open, merged, closed or draft.
function prGlyph(state: string | undefined) {
  if (state === "merged") return "git.pullrequest.merged" as const;
  if (state === "closed") return "git.pullrequest.closed" as const;
  if (state === "draft") return "git.pullrequest.draft" as const;
  return "git.pullrequest" as const;
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
}: {
  state: string | undefined;
  read: LinkedPullRequest | undefined;
  t: Translate;
  issue: boolean;
}) {
  const live = !issue && state !== "merged" && state !== "closed";
  if (!live) return null;
  const conflicts = read?.mergeable === "conflicting";
  const hasChecks = !!read?.checks;
  if (!hasChecks && !conflicts) return null;
  return (
    <div className="acpmux-pr-card__status">
      {hasChecks ? (
        <Checks read={read} t={t} conflicts={conflicts} />
      ) : (
        conflicts && <span className="acpmux-pr-card__conflicts">{t("header.prConflicts")}</span>
      )}
    </div>
  );
}

function Slot({
  hold,
  leaving,
  shown,
  row,
  children,
}: {
  hold: boolean;
  leaving: boolean;
  shown: boolean;
  row: PlaceholderRow;
  children: ReactNode;
}) {
  const [faded, setFaded] = useState(false);
  if (hold) return <Placeholder row={row} />;
  return (
    <div className="acpmux-pr-card__slot">
      {children}
      {leaving && shown && !faded && <Placeholder row={row} onAnimationEnd={() => setFaded(true)} />}
    </div>
  );
}

function Branches({ read, t }: { read: LinkedPullRequest | undefined; t: Translate }) {
  if (!read?.baseRef || !read.headRef) return null;
  const headRef = read.headRef;
  return (
    <div className="acpmux-pr-card__branches">
      <span className="acpmux-pr-card__branchChip">
        <span className="acpmux-pr-card__branch">{read.baseRef}</span>
        <span className="acpmux-pr-card__branchArrow" aria-hidden="true">
          ←
        </span>
        <span className="acpmux-pr-card__branch acpmux-pr-card__branchHead">{headRef}</span>
      </span>
      <CopyButton text={headRef} label={t("turn.copy")} className="acpmux-pr-card__copyBtn" size={12} />
    </div>
  );
}

/// How many check names the inline drawer lists before it stops with "…".
const NAMES_SHOWN = 8;

/// An open pull request's CI checks, said in words with an inline expandable drawer for failing or
/// running check names (no nested floating tooltip on top of the hover card). Passed checks recede
/// to muted text whenever a failure or running check is present, so the failure owns the eye.
function Checks({ read, t, conflicts }: { read: LinkedPullRequest | undefined; t: Translate; conflicts: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const checks = read?.checks;
  if (!checks) return null;
  if (checks.total === 0) {
    return (
      <div className="acpmux-pr-card__checks">
        <span className="acpmux-pr-card__checksLeft">
          <span>{t("header.prNoChecks")}</span>
          {conflicts && <span className="acpmux-pr-card__conflicts">{t("header.prConflicts")}</span>}
        </span>
      </div>
    );
  }
  const rows = read?.checkList ?? [];
  const failedRows = rows.filter((check) => check.state === "failed");
  const runningRows = rows.filter((check) => check.state === "pending");
  const failed = failedRows.length || 0;
  const failing = failed > 0 || checks.state === "failing" ? failed || checks.total - checks.passed : 0;
  const pending = Math.max(0, checks.total - checks.passed - failing);
  const marked = failedRows.filter((check) => check.onBase === true).length;
  const onBase = Math.min(checks.failingOnBase ?? marked, failing);
  const allOnBase = onBase > 0 && onBase >= failing;
  const counts = { passed: checks.passed, total: checks.total, failed: failing };
  const sentence =
    failing > 0
      ? onBase > 0
        ? t("prCard.checksFailingOnBase", { ...counts, onBase })
        : t("prCard.checksFailing", counts)
      : t("prCard.checks", counts);
  const hasDrawer = failedRows.length + runningRows.length > 0;
  const toggleDrawer = (event: React.MouseEvent<HTMLButtonElement>) => {
    event.preventDefault();
    event.stopPropagation();
    setExpanded((prev) => !prev);
  };
  return (
    <div className="acpmux-pr-card__checksWrap">
      <div className="acpmux-pr-card__checks" data-state={checks.state} data-on-base={allOnBase ? "all" : undefined}>
        <span className="acpmux-pr-card__sr">{sentence}</span>
        <span className="acpmux-pr-card__checksLeft">
          <span className="acpmux-pr-card__checksName" aria-hidden="true">
            {t("prCard.checksName")}
          </span>
          <span className="acpmux-pr-card__passed" aria-hidden="true">
            <span className="acpmux-pr-card__count">{checks.passed}</span> {t("prCard.checksPassed")}
          </span>
          {failing > 0 && pending > 0 && (
            <span className="acpmux-pr-card__pending" aria-hidden="true">
              <span className="acpmux-pr-card__count">{pending}</span> {t("prCard.checksRunning")}
            </span>
          )}
          {conflicts && <span className="acpmux-pr-card__conflicts">{t("header.prConflicts")}</span>}
        </span>
        {failing > 0 ? (
          hasDrawer ? (
            <Button
              type="button"
              bare
              className="acpmux-pr-card__checksToggle"
              data-kind={allOnBase ? "base" : "fail"}
              aria-expanded={expanded}
              onClick={toggleDrawer}
            >
              <span className="acpmux-pr-card__failed">
                <span className="acpmux-pr-card__count">{failing}</span> {t("prCard.checksFailed")}
              </span>
              {onBase > 0 && (
                <span className="acpmux-pr-card__onBase">
                  {t("sessionInfo.changes.failingOnBase", { count: onBase })}
                </span>
              )}
              <span className="acpmux-pr-card__checksChev" aria-hidden="true">
                <Icon name="disclosure.expanded" size={12} />
              </span>
            </Button>
          ) : (
            <span className="acpmux-pr-card__checksBadge" data-kind={allOnBase ? "base" : "fail"}>
              <span className="acpmux-pr-card__failed" aria-hidden="true">
                <span className="acpmux-pr-card__count">{failing}</span> {t("prCard.checksFailed")}
              </span>
              {onBase > 0 && (
                <span className="acpmux-pr-card__onBase" aria-hidden="true">
                  {t("sessionInfo.changes.failingOnBase", { count: onBase })}
                </span>
              )}
            </span>
          )
        ) : pending > 0 ? (
          hasDrawer ? (
            <Button
              type="button"
              bare
              className="acpmux-pr-card__checksToggle"
              data-kind="pending"
              aria-expanded={expanded}
              onClick={toggleDrawer}
            >
              <span className="acpmux-pr-card__pending">
                <span className="acpmux-pr-card__count">{pending}</span> {t("prCard.checksRunning")}
              </span>
              <span className="acpmux-pr-card__checksChev" aria-hidden="true">
                <Icon name="disclosure.expanded" size={12} />
              </span>
            </Button>
          ) : (
            <span className="acpmux-pr-card__pending" aria-hidden="true">
              <span className="acpmux-pr-card__count">{pending}</span> {t("prCard.checksRunning")}
            </span>
          )
        ) : null}
      </div>
      {expanded && hasDrawer && (
        <div className="acpmux-pr-card__checksDrawer">
          {failedRows.slice(0, NAMES_SHOWN).map((check, index) => (
            <CheckRow
              key={`f:${index}:${check.name}`}
              name={check.name}
              url={check.url}
              state={check.onBase ? "base" : "failed"}
            />
          ))}
          {runningRows.slice(0, Math.max(0, NAMES_SHOWN - failedRows.length)).map((check, index) => (
            <CheckRow key={`p:${index}:${check.name}`} name={check.name} url={check.url} state="pending" />
          ))}
          {failedRows.length + runningRows.length > NAMES_SHOWN && <div className="acpmux-pr-card__checkMore">…</div>}
        </div>
      )}
    </div>
  );
}

function CheckRow({ name, url, state }: { name: string; url?: string; state: "failed" | "base" | "pending" }) {
  const body = (
    <>
      <span className="acpmux-pr-card__checkIcon" aria-hidden="true">
        {state === "pending" ? <span className="acpmux-pr-card__checkSpin" /> : <Icon name="status.error" size={12} />}
      </span>
      <span className="acpmux-pr-card__checkName">{name}</span>
      {url && (
        <span className="acpmux-pr-card__checkArrow" aria-hidden="true">
          ↗
        </span>
      )}
    </>
  );
  if (url) {
    return (
      <a className="acpmux-pr-card__checkRow" data-state={state} href={url} rel="noreferrer">
        {body}
      </a>
    );
  }
  return (
    <div className="acpmux-pr-card__checkRow" data-state={state}>
      {body}
    </div>
  );
}

/// The review decision and the labels, paired neatly with the author row.
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
const LABEL_TONES = 8;

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

function toneOf(text: string, tones: number): number {
  let hash = 0;
  for (const character of text) hash = (hash * 31 + character.codePointAt(0)!) % 4096;
  return hash % tones;
}

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
                <span className="acpmux-pr-card__kindCount">
                  {(total.additions + total.deletions).toLocaleString()}
                </span>
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

function Freshness({
  answer,
  now,
  t,
  language,
  held,
  settled,
}: {
  answer: { fetchedAt?: number; reading: boolean } | undefined;
  now: number;
  t: Translate;
  language: PaneLanguage;
  held?: boolean;
  settled?: boolean;
}) {
  if (!answer) return null;
  if (held) return answer.reading ? <div className="acpmux-pr-card__sr">{t("prCard.reading")}</div> : null;
  const at = Number.isFinite(answer.fetchedAt) ? answer.fetchedAt! * 1000 : undefined;
  if (at == null) return answer.reading ? <div className="acpmux-pr-card__age">{t("prCard.reading")}</div> : null;
  const staleMs = settled ? SETTLED_STALE_MS : STALE_MS;
  if (now - at < staleMs && !answer.reading) return null;
  return <div className="acpmux-pr-card__age">{t("prCard.read", { ago: relativeTime(at, now, language) })}</div>;
}

const MONOGRAM_TONES = 6;

function Monogram({ login }: { login: string }) {
  const first = login.codePointAt(0);
  const letter = first == null ? "?" : String.fromCodePoint(first).toUpperCase();
  return (
    <span className="acpmux-pr-card__monogram" data-tone={toneOf(login, MONOGRAM_TONES)} aria-hidden="true">
      {letter}
    </span>
  );
}
