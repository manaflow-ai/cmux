import { projectName } from "./emptyStateModel";
import { type Translate } from "./i18n";
import type { FolderTrustAsk } from "./useFolderTrustAsk";

/// What the trust question is about, in words: the repository (`repo`, when the folder is in one
/// below home), else the folder. Its name, never its path cut to "/User…".
export function trustSubject(ask: Pick<FolderTrustAsk, "cwd" | "repo" | "via">) {
  const name = (path: string) => projectName(path) ?? path;
  return {
    folder: name(ask.cwd),
    repo: ask.repo ? name(ask.repo.root) : undefined,
    /// The answer came from the repository as a whole (the folder is in it, or one of its worktrees).
    viaRepo: Boolean(ask.repo && ask.via === ask.repo.root),
    /// The answer came from a parent folder that is not the repository.
    viaFolder: ask.via && ask.via !== ask.repo?.root ? name(ask.via) : undefined,
    /// The folder is the repository's main working tree: trusting it and the repository are one.
    atRoot: Boolean(ask.repo && ask.repo.root === ask.cwd),
  };
}

/// What a trusted folder's answer says: through its repository, its worktree's root, the
/// repository itself (only when a person's answer for it holds, not a rule's: `recorded`), or
/// the folder.
export function trustedLabel(t: Translate, scope: Pick<FolderTrustAsk, "cwd" | "repo" | "via"> & { recorded?: false }) {
  const { folder, repo, viaRepo, viaFolder, atRoot } = trustSubject(scope);
  if (viaRepo && repo) return t("trust.trustedViaRepo", { repo });
  if (viaFolder) return t("trust.trustedVia", { folder: viaFolder });
  if (atRoot && repo && scope.recorded !== false) return t("trust.trustedRepo", { repo });
  return t("trust.trusted", { folder });
}
