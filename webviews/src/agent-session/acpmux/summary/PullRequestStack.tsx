// The chat's pull requests over the composer: a compact "N PRs" control that opens the chips (Leo,
// 2026-10-30: "you guys fucking removed the # prs thing entirely instead of just simply fucking
// doing it", then "BUT IF IT'S ONLY N PRS DON'T FUCKIGN TAKE THE ENTIRE ROW AND FUCKING BLANK IT
// OUT"). It is the collapsed count the dock had before cmux#26082 moved the pills into each
// message's action row (#26441 aligned it last); those pills stay.
//
// Folded, the count is one content-sized control on a row that is already there: the composer's
// quiet row, beside the permission mode (Composer.tsx draws it through PullRequestCountSlot), so it
// adds no row, with or without the running tray. Its highlight covers only itself, and it opens on
// the click, with no fade-in (Leo, 2026-10-24: "You click, you get a response, period"). Opened,
// the chips stand in the bottom stack right over the composer (PullRequestList), one per pull
// request at the card's full width, each with the reply links' hover card. A row carries no control
// of its own: no control repeats on every row (the rulebook's visual verdict). A chip is dismissed
// from its own menu (a right-click, or Shift-F10 on a focused row: "Dismiss pull request #N"), or
// with Delete or Backspace on a focused row. The gallery compares other places for the count
// (bottomStackStyles.gallery.ts, `data-pr-control`).
import { createContext, useContext, useId, useState, type KeyboardEvent, type ReactNode } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useHeaderState } from "../header/headerState";
import { GitHubMark } from "../conversation/icons";
import { ContextMenu } from "../../../ui/ContextMenu";
import { LinkHoverCard } from "../chips/LinkHoverCard";
import { useSiteInfo } from "../chips/linkStore";
import { useHoverCard } from "../chips/useHoverCard";
import { rowIconSize } from "../icons/iconSize";
import type { SummaryPullRequest } from "./transcriptPullRequests";

const ROW_ICON = rowIconSize(12);

/// Where the folded count sits: the composer's quiet row (the live pane), or a gallery comparison
/// (`data-pr-control` on the document): on the running tray's header line, or over the composer's
/// left edge. The tray placement falls back to the quiet row when no tray shows.
export type PullRequestControlPlacement = "quiet" | "tray" | "above";

export function pullRequestControlLook(): PullRequestControlPlacement {
  const value = typeof document === "undefined" ? undefined : document.documentElement.dataset.prControl;
  return value === "tray" || value === "above" ? value : "quiet";
}

type Stack = {
  prs: readonly SummaryPullRequest[];
  chips: readonly SummaryPullRequest[];
  open: boolean;
  toggle(): void;
  dismiss(url: string, index: number): void;
  listId: string;
  placement: PullRequestControlPlacement;
};

const StackContext = createContext<Stack | undefined>(undefined);

const storageKey = (sessionId: string) => `acpmux.prDock.dismissed.${sessionId}`;

/// The pull request URLs dismissed in this chat, the same list the dock kept before cmux#26082
/// (PullRequestDockLegacy.tsx), so a shortcut dismissed then stays dismissed.
function readDismissed(sessionId: string | undefined): string[] {
  if (!sessionId) return [];
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey(sessionId)) ?? "[]");
    return Array.isArray(value) ? value.filter((url): url is string => typeof url === "string") : [];
  } catch {
    return [];
  }
}

function writeDismissed(sessionId: string | undefined, urls: readonly string[]): void {
  if (!sessionId) return;
  try {
    localStorage.setItem(storageKey(sessionId), JSON.stringify(urls));
  } catch {
    // Without storage the chip stays hidden until the page reloads.
  }
}

/// The chat's pull requests for the count and the list under it. Whether the list is open, and what
/// was dismissed, belong to one chat. The count names every pull request
/// Session Info's Changes names, a dismissed one too; dismissing a chip hides only that shortcut.
export function PullRequestStackProvider({
  prs,
  sessionId,
  placement,
  children,
}: {
  prs: readonly SummaryPullRequest[];
  sessionId?: string;
  placement: PullRequestControlPlacement;
  children: ReactNode;
}) {
  const [opened, setOpened] = useState(false);
  const [dismissed, setDismissed] = useState(() => readDismissed(sessionId));
  // Another chat: its own fold and dismissals (the composer under this keeps its element).
  const [chat, setChat] = useState(sessionId);
  if (chat !== sessionId) {
    setChat(sessionId);
    setOpened(false);
    setDismissed(readDismissed(sessionId));
  }
  const listId = useId();
  const chips = prs.filter((pr) => !dismissed.includes(pr.url));
  const open = opened && chips.length > 0;
  const value: Stack | undefined =
    prs.length === 0
      ? undefined
      : {
          prs,
          chips,
          open,
          listId,
          placement,
          toggle: () => setOpened(!open),
          dismiss: (url, index) => {
            const next = [...dismissed, url];
            setDismissed(next);
            writeDismissed(sessionId, next);
            // Focus moves to the row now in that place. With none left the count is disabled (it can
            // take no focus), so focus goes on to the composer's prompt, where the person types next.
            requestAnimationFrame(() => {
              const rows = document.querySelectorAll<HTMLElement>(".acpmux-pr-stack__link");
              (
                rows[Math.min(index, rows.length - 1)] ??
                document.querySelector<HTMLElement>(
                  '.acpmux-composer [contenteditable="true"], .acpmux-composer textarea',
                )
              )?.focus();
            });
          },
        };
  return <StackContext.Provider value={value}>{children}</StackContext.Provider>;
}

/// The folded count, "2 PRs" and its chevron, as one content-sized button.
export function PullRequestCount() {
  const t = useT();
  const stack = useContext(StackContext);
  if (!stack) return null;
  const count = t(stack.prs.length === 1 ? "prDock.countOne" : "prDock.count", { count: String(stack.prs.length) });
  return (
    <button
      type="button"
      className="acpmux-pr-count"
      aria-expanded={stack.open}
      aria-controls={stack.open ? stack.listId : undefined}
      disabled={stack.chips.length === 0}
      onClick={stack.toggle}
    >
      <Icon name="git.pullrequest" size={ROW_ICON} row />
      <span className="acpmux-pr-count__label">{count}</span>
      <Icon name={stack.open ? "disclosure.expanded" : "disclosure.collapsed"} size={ROW_ICON} row />
    </button>
  );
}

/// The count where it sits in the composer's quiet row (Composer.tsx): only for that placement.
export function PullRequestCountSlot() {
  const stack = useContext(StackContext);
  return stack?.placement === "quiet" ? <PullRequestCount /> : null;
}

/// The count for a gallery comparison that sits in the bottom stack itself, `at` its place.
export function PullRequestCountInStack({ at }: { at: Exclude<PullRequestControlPlacement, "quiet"> }) {
  const stack = useContext(StackContext);
  if (stack?.placement !== at) return null;
  return (
    <div className="acpmux-pr-count-host" data-placement={stack.placement}>
      <PullRequestCount />
    </div>
  );
}

/// The opened list: one full-width chip per pull request, in the bottom stack over the composer.
export function PullRequestList() {
  const stack = useContext(StackContext);
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  if (!stack?.open) return null;
  return (
    <section className="acpmux-pr-stack" aria-label={t("prDock.label")}>
      <ul id={stack.listId} className="acpmux-pr-stack__list">
        {stack.chips.map((pr, index) => {
          const followed = live?.url === pr.url;
          const state = followed ? live.state : pr.state;
          const title = (followed ? live.title : undefined) || pr.title || "";
          return (
            <li key={pr.url} className="acpmux-pr-stack__chip">
              <ContextMenu
                className="acpmux-pr-stack__menu"
                items={[
                  {
                    id: "dismiss",
                    ariaLabel: t("prDock.dismiss", { number: pr.number }),
                    label: (
                      <>
                        {t("prDock.dismiss", { number: pr.number })}
                        <span className="ui-menu-shortcut">⌫</span>
                      </>
                    ),
                    onSelect: () => stack.dismiss(pr.url, index),
                  },
                ]}
              >
                <PullRequestChip
                  pr={pr}
                  state={state}
                  title={title}
                  // Delete or Backspace on a focused row dismisses it, as its menu's Dismiss does.
                  onKeyDown={(event) => {
                    if (event.key !== "Delete" && event.key !== "Backspace") return;
                    event.preventDefault();
                    stack.dismiss(pr.url, index);
                  }}
                >
                  <span className="acpmux-pr-stack__mark" aria-hidden="true">
                    <Icon name="git.pullrequest" size={14} />
                  </span>
                  <span className="acpmux-pr-stack__label">
                    <span className="acpmux-pr-stack__number">#{pr.number}</span>
                    <span className="acpmux-pr-stack__repo">{pr.repo.split("/").pop()}</span>
                    {title && <span className="acpmux-pr-stack__title">{title}</span>}
                  </span>
                </PullRequestChip>
              </ContextMenu>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/// One chip's link and its hover card, the same card as a pull request link in a reply.
function PullRequestChip({
  pr,
  state,
  title,
  onKeyDown,
  children,
}: {
  pr: SummaryPullRequest;
  state: string;
  title: string;
  onKeyDown: (event: KeyboardEvent<HTMLAnchorElement>) => void;
  children: ReactNode;
}) {
  const hover = useHoverCard();
  const site = useSiteInfo(pr.url);
  const [chip, setChip] = useState<HTMLAnchorElement | null>(null);
  const card = useId();
  return (
    <>
      <a
        ref={setChip}
        className="acpmux-summary-row acpmux-summary-link acpmux-pr-stack__link"
        href={pr.url}
        data-state={state}
        aria-describedby={hover.open ? card : undefined}
        onKeyDown={onKeyDown}
        {...hover.trigger}
      >
        {children}
      </a>
      <LinkHoverCard
        id={card}
        href={pr.url}
        anchor={chip}
        hover={hover}
        mark={<GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />}
        siteTitle={site?.title}
        pullRequest={{ repo: pr.repo, number: pr.number, title, state }}
        side="top"
      />
    </>
  );
}
