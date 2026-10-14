import { translate } from "../i18n";
import { newWorktree } from "../startFolder";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The folder an offer that asks for a worktree starts in (cx-807da): a new git worktree of the
/// offer's folder, made by the host as New Worktree makes one. A worktree the host would first ask
/// about (not a folder it lets chats use) starts nothing.
export async function offerWorktree(callNative: Native, cwd: string): Promise<string> {
  let folder: string | undefined;
  await newWorktree(callNative, cwd, (picked) => {
    folder = picked;
  });
  if (!folder) throw new Error(translate("worktree.failed"));
  return folder;
}
