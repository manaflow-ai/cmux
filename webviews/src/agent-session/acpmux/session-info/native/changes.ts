// Session Info's Changes, drawn by the App (ChangesSection.tsx): every pull request the chat opened
// or changed, open ones first (changesOrder), five then Show more. A row is its title (its owner
// beside it), then `repo #N`, its lines and comments; its failing checks or its checks' state at
// the end; its state the glyph and tone alone. A click opens it beside the chat.
import type { StringKey, Translate } from "../../i18n";
import type { SummaryPullRequest } from "../../summary/sessionSummary";
import { CHANGES_SHOWN, changesOrder, glyphState, KINDS, type SessionInfoPullRequestStatus } from "../ChangesSection";
import { PULL_REQUEST_ICONS, type PullRequestGlyphState } from "../PullRequestGlyph";
import {
  NATIVE_PACK_ICON,
  type NativeInfoActions,
  type NativeInfoRow,
  type NativeInfoSection,
  type NativeInfoTone,
} from "./model";
import { nativeExternalUrl, safeExternalUrl } from "./links";

const TONES: Record<PullRequestGlyphState, NativeInfoTone> = {
  open: "done",
  draft: "muted",
  conflicting: "failed",
  merged: "accent",
  closed: "muted",
};
const SYMBOL_COLORS: Record<PullRequestGlyphState, string> = {
  open: "green",
  merged: "purple",
  draft: "yellow",
  closed: "red",
  conflicting: "red",
};
/// The state glyph's label (ChangesSection's screen-reader label): the row's tooltip here.
const STATE_LABELS: Record<PullRequestGlyphState, StringKey> = {
  open: "sessionInfo.changes.open",
  draft: "sessionInfo.changes.draft",
  merged: "header.prBadge.merged",
  closed: "header.prBadge.closed",
  conflicting: "header.prConflicts",
};
const CHECK_LABELS: Record<string, StringKey> = {
  passing: "rail.checksPassing",
  pending: "rail.checksPending",
};

export type ChangesInput = {
  /// The pull requests Changes lists (SessionInfo's `visibleChanges`), in any order.
  pullRequests: readonly SummaryPullRequest[];
  statuses: Readonly<Record<string, SessionInfoPullRequestStatus>>;
  /// Opens a pull request in the browser beside the chat.
  onOpenBeside?: (url: string) => void;
  onCopyText?: (text: string) => void;
  onDismiss?: (url: string) => void;
  /// The section is unfolded (`sections.changes`).
  open: boolean;
  /// Every row shows, past the first five (ChangesSection's own `all`, held by the caller).
  expanded?: boolean;
  onExpandedChange?: (expanded: boolean) => void;
};

export function changesSection(
  input: ChangesInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { pullRequests, statuses, onOpenBeside, onExpandedChange } = input;
  const openUrl = nativeExternalUrl(onOpenBeside);
  if (pullRequests.length === 0) return undefined;
  const expanded = input.expanded === true;
  const ordered = changesOrder(pullRequests, statuses);
  const folds = ordered.length > CHANGES_SHOWN;
  const shown = folds && !expanded ? ordered.slice(0, CHANGES_SHOWN) : ordered;
  const rows = shown.map((pr): NativeInfoRow => {
    const live = statuses[pr.url] ?? {};
    const state = glyphState(pr, live);
    const ended = state === "merged" || state === "closed";
    const repoName = pr.repo.split("/").pop() ?? pr.repo;
    const checks = ended ? undefined : live.checks;
    const failing = ended ? 0 : (live.failing ?? (checks === "failing" ? -1 : 0));
    const onBase = Math.min(Math.max(0, live.failingOnBase ?? 0), Math.max(0, failing));
    const comments = live.comments ?? 0;
    const line = [`${repoName} #${pr.number}`];
    if (live.additions !== undefined && live.deletions !== undefined)
      line.push(`+${live.additions} -${live.deletions}`);
    if (comments > 0) line.push(t("sessionInfo.changes.comments", { count: comments }));
    let trailing: string | undefined;
    if (failing !== 0) {
      trailing = failing > 0 ? t("sessionInfo.changes.failing", { count: failing }) : t("rail.checksFailing");
      if (onBase > 0) trailing += ` ${t("sessionInfo.changes.failingOnBase", { count: onBase })}`;
    } else if (checks && CHECK_LABELS[checks]) trailing = t(CHECK_LABELS[checks]!);
    const reference = `${pr.repo}#${pr.number}`;
    const menu = [
      ...(safeExternalUrl(pr.url)
        ? [
            {
              label: t("sessionInfo.changes.openBeside"),
              action: actions.add(`changes.openMenu:${pr.url}`, () => openUrl(pr.url)),
            },
          ]
        : []),
      ...(input.onCopyText
        ? [
            {
              label: t("sessionInfo.changes.copyLink"),
              action: actions.add(`changes.copyLink:${pr.url}`, () => input.onCopyText!(pr.url)),
            },
            {
              label: t("sessionInfo.changes.copyReference"),
              action: actions.add(`changes.copyReference:${pr.url}`, () => input.onCopyText!(reference)),
            },
          ]
        : []),
      ...(input.onDismiss
        ? [
            {
              label: t("prDock.dismiss", { number: pr.number }),
              action: actions.add(`changes.dismiss:${pr.url}`, () => input.onDismiss!(pr.url)),
            },
          ]
        : []),
    ];
    const breakdown = live.breakdown;
    const hoverDetail = breakdown
      ? KINDS.filter((kind) => breakdown[kind])
          .map((kind) => {
            const totals = breakdown[kind]!;
            return `${t(`sessionInfo.changes.${kind}` as StringKey)} +${totals.additions} -${totals.deletions}`;
          })
          .join(" · ")
      : undefined;
    return {
      id: pr.url,
      // The pack's glyph, as the page's row draws it (PullRequestGlyph), not an SF Symbol.
      symbol: `${NATIVE_PACK_ICON}${PULL_REQUEST_ICONS[state]}`,
      title: (live.title ?? pr.title) || `#${pr.number}`,
      ...(live.owner ? { detail: live.owner } : {}),
      subtitle: line.join("  "),
      ...(trailing ? { trailing } : {}),
      tone: failing !== 0 ? "failed" : TONES[state],
      symbolColor: SYMBOL_COLORS[state],
      help: `${t(STATE_LABELS[state])} · ${pr.url}`,
      hover: {
        title: (live.title ?? pr.title) || `#${pr.number}`,
        ...(hoverDetail ? { detail: hoverDetail } : {}),
      },
      ...(safeExternalUrl(pr.url)
        ? {
            action: actions.add(`changes.open:${pr.url}`, () => openUrl(pr.url)),
          }
        : {}),
      ...(menu.length ? { menu, menuLabel: t("sessionInfo.changes.more", { reference }) } : {}),
    };
  });
  return {
    id: "changes",
    group: "made",
    title: t("header.changes"),
    meta: String(pullRequests.length),
    open: input.open,
    foldable: true,
    reorderable: true,
    rows,
    ...(folds && onExpandedChange
      ? {
          more: {
            label: t(expanded ? "sessionInfo.changes.showLess" : "sessionInfo.changes.showMore"),
            action: actions.add("changes.more", () => onExpandedChange(!expanded)),
          },
        }
      : {}),
  };
}
