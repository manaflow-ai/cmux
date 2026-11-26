// l10n-allow-file: gallery fixtures, not shipped UI.
// The GitHub page's issues view (GitHubIssues.tsx): the same component main.tsx draws for
// `#/issues?repo=…` and `#/issue?url=…`, over the mock `cmux.github.*` provider. A row's click
// routes in place, so the list variants open their issue as the page does.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { GitHubIssues } from "./GitHubIssues";
import { IssuesStore } from "./issuesStore";
import { mockIssue, mockIssueData, MOCK_ISSUE_URL, MOCK_REPO, type MockIssueData } from "./mockIssues";
import { MockGitHubProvider } from "./mockProvider";
import { issueRoute, issuesRoute } from "./types";

type Props = {
  /** `list`: the repository's issues; `issue`: the mock issue. */
  route: "list" | "issue";
  data?: MockIssueData;
};

function IssuesGallery({ route, data = mockIssueData }: Props) {
  const [store] = useState(() => {
    // The store routes its own clicks (a row, All issues) in place of `location.hash`.
    const held: { store?: IssuesStore } = {};
    held.store = new IssuesStore(
      new MockGitHubProvider(undefined, undefined, undefined, null, data),
      (hash) => void held.store?.route(hash),
      () => false,
    );
    return held.store;
  });
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.route(route === "list" ? issuesRoute(MOCK_REPO) : issueRoute(MOCK_ISSUE_URL));
    return () => store.stop();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a fixture's props are fixed
  }, [store]);
  // A fixed clock, so every capture says the same age.
  return <GitHubIssues store={store} strings={strings} now={() => Date.parse("2026-11-05T03:00:00Z")} />;
}

export default componentEntry<Props>({
  id: "pages.github.issues",
  title: "GitHub issues",
  area: "Pages",
  experimental: true,
  height: 900,
  widths: { narrow: 360, normal: 640, wide: 1600 },
  covers: ["pages/github/GitHubIssues.tsx", "pages/github/issuesStore.ts"],
  load: async () => IssuesGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    list: {
      note: "A repository's issues, newest activity first: state glyph, title, coloured labels, number, author, last activity and comment count. Pull requests are left out by the host. A row opens its issue in place.",
      props: { route: "list" },
    },
    "list-empty": {
      note: "A repository with no issues.",
      props: { route: "list", data: { ...mockIssueData, issues: [] } },
    },
    "list-failed": {
      note: "The host could not read the issues (no cmux GitHub App access and no gh sign-in): the header says so.",
      props: { route: "list", data: { ...mockIssueData, issues: "failed" } },
    },
    issue: {
      note: "One issue: state, author, labels, the body on the page's GitHub Markdown renderer, then its comments in time order.",
      props: { route: "issue" },
    },
    "issue-closed-no-comments": {
      note: "A closed issue (completed) with no body and no comments yet.",
      props: {
        route: "issue",
        data: {
          ...mockIssueData,
          issue: {
            issue: { ...mockIssue, state: "closed", state_reason: "completed", body: "", comments: 0, labels: [] },
            comments: [],
          },
        },
      },
    },
    "issue-not-planned": {
      note: "Closed as not planned: grey glyph and badge.",
      props: {
        route: "issue",
        data: {
          ...mockIssueData,
          issue: { issue: { ...mockIssue, state: "closed", state_reason: "not_planned" }, comments: [] },
        },
      },
    },
    "issue-failed": {
      note: "The host could not read the issue.",
      props: { route: "issue", data: { ...mockIssueData, issue: "failed" } },
    },
  },
});
