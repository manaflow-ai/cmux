// l10n-allow-file: gallery fixtures (sample URLs), not shipped UI.
import { componentEntry, type ChipHostFixture, type PullRequestFixture } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import type { ReactNode } from "react";

type UrlChipProps = { href: string; icon?: ReactNode; children: ReactNode };

const FAVICON =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="4" fill="#e07a5f"/><path d="M4 8h8M8 4v8" stroke="#fff" stroke-width="2"/></svg>',
  );

const host: ChipHostFixture = {
  sites: {
    "https://docs.example.test/guide": { title: "Example docs", icon: FAVICON },
  },
};

// A pull request chip's card. The fixture is what the host answers `pr.inspect` with: the pull
// request as `gh pr view --json` reads it, plus when cmux last read it.
const PULL_REQUEST = "https://github.com/manaflow-ai/cmux/pull/22777";
const file = (path: string, additions: number, deletions: number) => ({ path, additions, deletions });
const FILES = [
  file("webviews/src/agent-session/acpmux/chips/PullRequestCard.tsx", 231, 48),
  file("webviews/src/agent-session/acpmux/styles.css", 36, 1),
  file("webviews/src/fileKinds.ts", 162, 0),
  file("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPanePullRequest.swift", 97, 14),
  file("webviews/test/file-kinds.test.ts", 131, 0),
  file("webviews/test/pr-card-content.test.tsx", 184, 0),
  file("webviews/src/agent-session/acpmux/mockFixture.ts", 12, 3),
  file("docs/ci/risk-tiers.md", 9, 2),
  file("webviews/src/agent-session/acpmux/Localizable.xcstrings", 1848, 0),
  file("bun.lock", 14, 6),
];
const pullRequest = (extra: Record<string, unknown> = {}) => ({
  url: PULL_REQUEST,
  number: 22777,
  title: "cmux NEXT: one pull request card for every pull request cmux mentions",
  state: "open",
  review: "changes_requested",
  mergeable: "conflicting",
  author: "teamleaderleo",
  updatedAt: new Date(minutesAgo(7)).toISOString(),
  baseRef: "feat-cmux-next",
  headRef: "cmux/pr-cards",
  labels: ["risk:normal", "agent"],
  additions: FILES.reduce((sum, entry) => sum + entry.additions, 0),
  deletions: FILES.reduce((sum, entry) => sum + entry.deletions, 0),
  changedFiles: FILES.length,
  files: FILES,
  checks: { state: "failing", passed: 89, total: 100 },
  checkList: [{ name: "cmux-next / cmux-next generated files", state: "failed" }],
  ...extra,
});
const prHost = (fixture: PullRequestFixture): ChipHostFixture => ({ pullRequests: { [PULL_REQUEST]: fixture } });
// The card opens with the link it already has and fills in when the host answers `pr.inspect`,
// so the stage waits for the pull request's own rows, not just for the card.
const openCard: Play = async (ctx) => {
  await ctx.hover({ selector: "a.cv-chip.is-web" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pr-card__changes"));
};

export default componentEntry<UrlChipProps>({
  id: "agent-pane.url-chip",
  title: "URL chips",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/chips/LinkChips.tsx#UrlChip",
    // Its hover card.
    "agent-session/acpmux/chips/LinkHoverCard.tsx#LinkHoverCard",
    "agent-session/acpmux/chips/PullRequestCard.tsx#PullRequestCardBody",
  ],
  load: () => import("./LinkChips").then((module) => module.UrlChip),
  styles: () =>
    Promise.all([
      import("../../shared/styles.css"),
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./chips.css"),
    ]),
  widths: { narrow: 360, normal: 640, wide: 860 },
  variants: {
    globe: { props: { href: "https://example.test/docs/getting-started", children: "example.test/docs" } },
    // The favicon and title cmux has show in the hover card the play opens; the chip keeps its text.
    "cached-favicon": {
      chipHost: host,
      props: { href: "https://docs.example.test/guide", children: "Example docs" },
      play: async (ctx) => {
        await ctx.hover({ selector: "a.cv-chip.is-web" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-link-preview"));
        await ctx.hover({ selector: ".cv-link-preview" });
        await ctx.click({ selector: ".cv-link-preview__open" });
      },
    },
    "token-url": {
      props: {
        href: "http://127.0.0.1:47811?token=0f3c9a7d51e2b8846a0c3f9e1d7b2a5c6e8f0a1b",
        children: "http://127.0.0.1:47811?token=0f3c9a7d51e2b8846a0c3f9e1d7b2a5c6e8f0a1b",
      },
      play: async (ctx) => {
        await ctx.hover({ selector: "a.cv-chip.is-web" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-link-preview"));
      },
    },
    // Design variations for Leo's hover-card review. `pull-request-polished` is the chosen
    // hierarchy: title, state/checks, author/time, compact diff, then secondary context.
    "pull-request-polished": {
      chipHost: prHost({ pullRequest: pullRequest(), fetchedAt: GALLERY_NOW / 1000 - 20 }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-polished-draft": {
      chipHost: prHost({
        pullRequest: pullRequest({
          title: "cmux NEXT: the composer keeps its caret on a slow send",
          state: "draft",
          review: "",
          mergeable: "mergeable",
          labels: ["risk:low"],
          checks: { state: "pending", passed: 12, total: 40 },
          checkList: [],
          files: [file("webviews/src/agent-session/acpmux/Composer.tsx", 41, 9)],
          additions: 41,
          deletions: 9,
          changedFiles: 1,
        }),
        fetchedAt: GALLERY_NOW / 1000 - 15,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-polished-merged": {
      chipHost: prHost({
        pullRequest: pullRequest({
          title: "nightly-next: new builds go to the Dev ring first and move to Nightly on a canary pass",
          state: "merged",
          mergeable: "",
          review: "approved",
          checks: { state: "failing", passed: 118, total: 122, failingOnBase: 4 },
          checkList: [],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-polished-long-title": {
      chipHost: prHost({
        pullRequest: pullRequest({
          title: "nightly-next: new builds go to the Dev ring first and move to Nightly on a canary pass",
          review: "",
          mergeable: "mergeable",
          labels: ["risk:high"],
          checks: { state: "passing", passed: 100, total: 100 },
          checkList: [],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    // The theme-color pass keeps all three semantic inks visible together: additions, deletions
    // and the passing/failing check count. The matrix renders this state in dark, light and
    // colorful terminal themes for before/after review.
    "pull-request-theme-colors": {
      chipHost: prHost({
        pullRequest: pullRequest({
          title: "cmux NEXT: terminal theme colors carry through status text",
          review: "approved",
          mergeable: "mergeable",
          labels: ["risk:normal", "theme"],
          checks: { state: "failing", passed: 97, total: 100 },
          checkList: [{ name: "cmux-next / web lint", state: "failed" }],
          files: [
            file("webviews/src/agent-session/acpmux/chips/linkCard.css", 22, 18),
            file("webviews/src/agent-session/acpmux/conversation/conversation.css", 30, 30),
            file("webviews/test/agent-status-colors.test.ts", 96, 0),
          ],
          additions: 148,
          deletions: 48,
          changedFiles: 3,
        }),
        fetchedAt: GALLERY_NOW / 1000 - 12,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#theme-colors" },
      play: openCard,
    },
    // A red the base branch already has: the compact ✓/✗ count says how many of the failures are not
    // this pull request's, and the ✗ reads muted when none of them are.
    "pull-request-base-reds": {
      chipHost: prHost({
        pullRequest: pullRequest({
          review: "",
          mergeable: "mergeable",
          checks: { state: "failing", passed: 98, total: 100, failingOnBase: 1 },
          checkList: [
            { name: "cmux-next / cmux-next generated files", state: "failed", onBase: true },
            { name: "cmux-next web / web lint (fast)", state: "failed" },
          ],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-all-reds-on-base": {
      chipHost: prHost({
        pullRequest: pullRequest({
          review: "approved",
          mergeable: "mergeable",
          checks: { state: "failing", passed: 98, total: 100, failingOnBase: 2 },
          checkList: [
            { name: "cmux-next / cmux-next generated files", state: "failed", onBase: true },
            { name: "cmux-next web / web lint (fast)", state: "failed", onBase: true },
          ],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-no-tests": {
      chipHost: prHost({
        pullRequest: pullRequest({
          title: "cmux NEXT: the composer keeps its caret on a slow send",
          review: "",
          mergeable: "mergeable",
          state: "draft",
          labels: ["risk:low"],
          checks: { state: "pending", passed: 12, total: 40 },
          checkList: [],
          files: [file("webviews/src/agent-session/acpmux/Composer.tsx", 41, 9)],
          additions: 41,
          deletions: 9,
          changedFiles: 1,
        }),
        fetchedAt: GALLERY_NOW / 1000 - 15,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    "pull-request-stale": {
      // GitHub would not answer (a rate limit): the card keeps the pull request and says how old
      // the copy is, instead of showing an error where the pull request should be.
      chipHost: prHost({
        pullRequest: pullRequest({ state: "merged", mergeable: "", review: "approved" }),
        fetchedAt: GALLERY_NOW / 1000 - 23 * 60,
      }),
      props: { href: PULL_REQUEST, children: "manaflow-ai/cmux#22777" },
      play: openCard,
    },
    // Merged: the pull request glyph in purple and no checks line (a merged pull request's reds
    // no longer matter), however red its last run was.
    "pull-request-merged": {
      chipHost: prHost({
        pullRequest: pullRequest({
          state: "merged",
          mergeable: "",
          review: "approved",
          checks: { state: "failing", passed: 118, total: 122, failingOnBase: 4 },
          checkList: [
            { name: "cmux-next / web lint (fast)", state: "failed", onBase: true },
            { name: "cmux-next / package tests", state: "failed", onBase: true },
            { name: "cmux-next / generated files", state: "failed", onBase: true },
            { name: "cmux-next / gallery", state: "failed", onBase: true },
          ],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "#22777" },
      play: openCard,
    },
    // Closed: the glyph in red, and no checks line either.
    "pull-request-closed": {
      chipHost: prHost({
        pullRequest: pullRequest({
          state: "closed",
          mergeable: "",
          review: "",
          labels: [],
          checks: { state: "passing", passed: 100, total: 100 },
          checkList: [],
        }),
        fetchedAt: GALLERY_NOW / 1000 - 20,
      }),
      props: { href: PULL_REQUEST, children: "#22777" },
      play: openCard,
    },
    "long-url": {
      props: {
        href: "https://example.test/research/2026/agent-session/gallery/fixtures?view=transcript&sort=recent&filter=public",
        children: "example.test/research/2026/agent-session/gallery/fixtures?view=transcript&sort=recent&filter=public",
      },
    },
  },
});
