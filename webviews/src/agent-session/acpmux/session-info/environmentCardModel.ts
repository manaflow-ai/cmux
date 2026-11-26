// The Environment card's reads (EnvironmentCard.tsx): the chat folder's branch from the host's
// `git.status`, and whether the pane's right gutter has room for the card beside the column.
import { useEffect, useState, useSyncExternalStore } from "react";
import { worktreeOf } from "../header/worktreePillModel";

/// The card's width and its gap to the pane's edge and to the column (environmentCard.css).
export const ENVIRONMENT_CARD_WIDTH = 220;
export const ENVIRONMENT_CARD_GAP = 12;

/// Where the chat's folder is: its branch, whether it is a linked worktree, and a detached head.
export type CardBranch = { branch?: string; worktree: boolean; detached: boolean };

/// A `git.status` reply's branch, or undefined for a folder in no repository (or no reply).
export function cardBranchOf(status: unknown): CardBranch | undefined {
  if (!status || typeof status !== "object") return undefined;
  const raw = status as Record<string, unknown>;
  if (typeof raw.root !== "string" || !raw.root) return undefined;
  const branch = typeof raw.branch === "string" && raw.branch ? raw.branch : undefined;
  return { branch, worktree: worktreeOf(status) !== undefined, detached: raw.detached === true };
}

/// Whether a pane `paneWidth` wide shows the card beside a column `column` wide (or the whole pane,
/// `fullWidth`), so it never lies over the transcript's text: the gutter right of the column holds the
/// card and a gap on each side.
export function environmentCardFits(paneWidth: number, column: number, fullWidth: boolean): boolean {
  if (fullWidth) return false;
  const gutter = (paneWidth - Math.min(column, paneWidth)) / 2;
  return gutter >= ENVIRONMENT_CARD_WIDTH + 2 * ENVIRONMENT_CARD_GAP;
}

const subscribeWidth = (listener: () => void) => {
  if (typeof window === "undefined") return () => undefined;
  window.addEventListener("resize", listener);
  return () => window.removeEventListener("resize", listener);
};
const paneWidth = () => (typeof window === "undefined" ? 0 : window.innerWidth);

/// The pane's width (the page is the pane), following resizes.
export function usePaneWidth(): number {
  return useSyncExternalStore(subscribeWidth, paneWidth, paneWidth);
}

/// The folder's branch while `live`, read again when `key` changes (a chat, a turn's end). A reply
/// for a folder the chat has left does not show.
export function useCardBranch(
  folder: string | undefined,
  readStatus: (cwd: string) => Promise<unknown>,
  live: boolean,
  key: string,
): CardBranch | undefined {
  const [found, setFound] = useState<{ folder: string; branch?: CardBranch }>();
  useEffect(() => {
    if (!folder || !live) return;
    let current = true;
    readStatus(folder).then(
      (status) => current && setFound({ folder, branch: cardBranchOf(status) }),
      () => current && setFound({ folder }),
    );
    return () => {
      current = false;
    };
  }, [folder, readStatus, live, key]);
  return found && found.folder === folder ? found.branch : undefined;
}
