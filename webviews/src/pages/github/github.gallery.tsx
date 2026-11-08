// l10n-allow-file: gallery fixtures, not shipped UI.
// The GitHub page (cmux-page://cmux.github/): the same GitHubPage main.tsx mounts, over the mock
// `cmux.github.*` provider instead of the host bridge. The layout variants are the hierarchy
// candidates of design/github-page.md; `split` ships.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { GitHubPage, type ChecksPlacement, type GitHubLayout, type PageWidth } from "./GitHubPage";
import { MockGitHubProvider, mockChecksPassed, mockDetails, mockPullRequest, MOCK_URL } from "./mockProvider";
import { GitHubStore } from "./store";
import type { DashboardChecks, PullRequestDetails, PullRequestReply } from "./types";

type Props = {
  answer?: PullRequestReply;
  details?: PullRequestDetails | null;
  layout?: GitHubLayout;
  checks?: DashboardChecks | null;
  checksPlacement?: ChecksPlacement;
  width?: PageWidth;
  /** Files opened inline once the page has its answer. */
  expand?: string[];
  /** The Merge button's first click, so its confirm shows. */
  confirmMerge?: boolean;
};

function GitHubGallery({
  answer,
  details,
  checks,
  checksPlacement,
  layout,
  width,
  expand = [],
  confirmMerge = false,
}: Props) {
  const [store] = useState(() => new GitHubStore(new MockGitHubProvider(answer, details, checks), () => false));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.route(`#/pull?url=${encodeURIComponent(MOCK_URL)}`).then(async () => {
      for (const file of expand) store.toggleFile(file);
      // The details answer lands a turn after the route's; the confirm needs them.
      await Promise.resolve();
      await Promise.resolve();
      if (confirmMerge) void store.merge();
    });
    return () => store.stop();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a fixture's props are fixed
  }, [store]);
  // A fixed clock, so every capture says the same age.
  return (
    <GitHubPage
      store={store}
      strings={strings}
      layout={layout}
      checksPlacement={checksPlacement}
      width={width}
      now={() => Date.parse("2026-11-05T03:00:00Z")}
    />
  );
}

const merged: PullRequestReply = {
  pullRequest: {
    ...mockPullRequest,
    state: "merged",
    review: "approved",
    checks: { state: "passed", passed: 7, total: 7 },
    checkList: mockPullRequest.checkList.map((check) => ({ ...check, state: "passed", onBase: false })),
  },
  fetchedAt: 1,
};

// A review bot's check table, as cmux#37993's body has it: a short Status column between two long
// ones, which the body's wrap rule used to squeeze to a letter a line.
const checkTable: PullRequestDetails = {
  ...mockDetails,
  body: [
    mockDetails.body,
    "",
    "| Check name | Status | Explanation |",
    "| --- | --- | --- |",
    "| Title check | Passed | The title names the change: main's scheduled nightly-next canary, launch smoke, and owned-pool rescue now read the one NIGHTLY feed. The diff does exactly this across the canary, launch smoke, re... |",
    "| Description check | Passed | The description covers the problem (the /next/ appcast froze on 2026-11-05), the resulting behavior, the per-file changes, and the testing commands with results. It also notes what was intentionally l... |",
    "| Docstring Coverage | Passed | No eligible functions found in the changed files. Skipping docstring coverage check. |",
    "| Linked Issues check | Passed | Check skipped because no linked issues were found for this pull request. |",
    "| Out of Scope Changes check | Passed | Check skipped because no linked issues were found for this pull request. |",
  ].join("\n"),
};

export default componentEntry<Props>({
  id: "pages.github",
  title: "GitHub pull request",
  area: "Pages",
  experimental: true,
  height: 1100,
  widths: { narrow: 360, normal: 640, wide: 1600 },
  covers: ["page:cmux.github", "pages/github/GitHubPage.tsx"],
  load: async () => GitHubGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    open: {
      note: "Shipped layout (split): description, files and conversation in the main column; checks (reds first, greens folded), reviewers and linked issues in the rail. One column when narrow.",
      props: {},
    },
    "width-fill": {
      note: "Shipped width: the whole pane less a 3% gutter (16-24px). The description's check table keeps Status on one line.",
      props: { details: checkTable },
    },
    "width-wide": {
      note: "Candidate: 94% of the pane up to 2200px, centered.",
      props: { details: checkTable, width: "wide" },
    },
    "width-column": {
      note: "Before: What's New's width, 84% of the pane up to 1560px, centered; a wide pane gives up its sides.",
      props: { details: checkTable, width: "column" },
    },
    "ci-failed-running": {
      note: "Shipped CI dashboard (top): tally, share done and ETA; failures with their step and log end; a matrix's shards as one row of pips; running with elapsed time; passed folded.",
      props: {},
    },
    "ci-rail": {
      note: "Candidate: the same dashboard in the rail. Long names and the log excerpt wrap in 320px.",
      props: { checksPlacement: "rail" },
    },
    "ci-passed": {
      note: "Every job done and green: one line, the rest folded.",
      props: { checks: mockChecksPassed },
    },
    "ci-before-read": {
      note: "Before the dashboard's first read: the cache's rollup, in the dashboard's place.",
      props: { checks: null },
    },
    "layout-rail": {
      note: "Candidate: the files in the rail beside the checks, as the first brief drew it. An opened diff has the rail's width only.",
      props: { layout: "rail", expand: ["Sources/Sidebar/SidebarList.swift"] },
    },
    "layout-single": {
      note: "Candidate: one column at every width, header first, then description, files, conversation, checks.",
      props: { layout: "single" },
    },
    "file-open": {
      note: "A file opened inline on the diff renderer, with Open in diff viewer under it.",
      props: { expand: ["Sources/Sidebar/SidebarList.swift"] },
    },
    "merge-confirm": {
      note: "Merge's first click: it names the method; the second merges the head shown.",
      props: { details: { ...mockDetails, mergeState: "clean" }, confirmMerge: true },
    },
    merged: {
      note: "Merged and approved, every check passed (folded to one line).",
      props: { answer: merged, details: { ...mockDetails, mergeState: "unknown" } },
    },
    "no-description": {
      note: "No body and no comments yet.",
      props: {
        details: { ...mockDetails, body: "", conversation: [], conversationTotal: 0, reviewers: [], linked: [] },
      },
    },
    reading: { note: "The first read, before gh answered.", props: { answer: { pullRequest: null, reading: true } } },
    unavailable: {
      note: "gh could not read it (not signed in).",
      props: { answer: { pullRequest: null, reading: false } },
    },
  },
});
