import type { StartedPullRequestName } from "./startedSessions";

/// `repo #N`, or `#N` when acpmux names no repository.
export const pullRequestName = (prs: StartedPullRequestName): string =>
  prs.repo ? `${prs.repo} #${prs.number}` : `#${prs.number}`;
