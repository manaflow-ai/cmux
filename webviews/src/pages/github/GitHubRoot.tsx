import { useSyncExternalStore } from "react";
import type { createStrings } from "../shared/i18n";
import { GitHubIssues } from "./GitHubIssues";
import type { IssuesStore } from "./issuesStore";
import { GitHubPage } from "./GitHubPage";
import type { GitHubStore } from "./store";
import { issuesRoute } from "./types";

/** The issues view when the route names one, else the pull request page. */
export function GitHubRoot({
  store,
  issues,
  strings,
}: {
  store: GitHubStore;
  issues: IssuesStore;
  strings: ReturnType<typeof createStrings>;
}) {
  const view = useSyncExternalStore(issues.subscribe, () => issues.getSnapshot().view);
  if (view) return <GitHubIssues store={issues} strings={strings} />;
  return <GitHubPage store={store} strings={strings} onIssues={(repo) => (location.hash = issuesRoute(repo))} />;
}
