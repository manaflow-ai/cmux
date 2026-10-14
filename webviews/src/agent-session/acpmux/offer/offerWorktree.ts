import { translate } from "../i18n";
import type { AcpmuxSessionOffer } from "../model";
import { newWorktree } from "../startFolder";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The worktree each offer got, by offer id: a Start that failed after the host made it (a trust
/// question, an agent that would not start) reuses it, so retries never leave more of them.
const made = new Map<string, string>();

/// The folder an offer that asks for a worktree starts in (cx-807da): a new git worktree of the
/// offer's folder, made by the host as New Worktree makes one. A worktree the host would first ask
/// about (not a folder it lets chats use) starts nothing.
export async function offerWorktree(callNative: Native, offer: AcpmuxSessionOffer): Promise<string> {
  const known = made.get(offer.offerId);
  if (known) return known;
  let folder: string | undefined;
  await newWorktree(callNative, offer.cwd, (picked) => {
    folder = picked;
  });
  if (!folder) throw new Error(translate("worktree.failed"));
  made.set(offer.offerId, folder);
  return folder;
}
