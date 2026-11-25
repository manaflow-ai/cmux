// l10n-allow-file: gallery fixtures (sample code), not shipped UI.
// The diff viewer page (cmux-page://cmux.diff/) on fixed patches: the real page entry (main.tsx)
// over an in-page cmuxPage host that serves the patch (src/gallery/frame/pages.ts).
import { diffPageEntry } from "../../gallery/format";
import { pageDensities, pageDensityPlay } from "../../gallery/pageDensityFixtures";
import type { PlayContext } from "../../gallery/play";

/** Plain English is a row of the "..." menu (toolbar-model.ts): open the menu, choose it once it can run. */
async function turnOnPlainEnglish(ctx: PlayContext): Promise<void> {
  await ctx.waitFor(() => ctx.document.querySelector("#options-button"), { capMs: 10_000 });
  await ctx.click({ selector: "#options-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-option="plain-english"]:not([aria-disabled="true"])'), {
    capMs: 10_000,
  });
  await ctx.click({ selector: '[data-option="plain-english"]' });
}

/** Marks the first three files viewed from their headers' Viewed buttons (hq #19495). */
async function markThreeViewed(ctx: PlayContext): Promise<void> {
  // Every file first (thirty files add 59 lines), so the count's total is the whole diff's.
  await ctx.waitFor(() => ctx.document.querySelector(".source-pill-additions")?.textContent === "+59", {
    capMs: 10_000,
  });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".file-review-viewed").length >= 3, { capMs: 10_000 });
  for (let index = 0; index < 3; index += 1) {
    const unviewed = ctx.document.querySelector<HTMLElement>('.file-review-viewed[aria-pressed="false"]');
    unviewed?.click();
    await ctx.waitFor(
      () => ctx.document.querySelectorAll('.file-review-viewed[aria-pressed="true"]').length >= index + 1,
      { capMs: 5_000 },
    );
  }
}

const before = `export function request(url: string) {
  return fetch(url).then((response) => response.json());
}

export function getJSON(url: string) {
  return request(url);
}
`;

const after = `import { withRetry } from "./retry";

export function request(url: string, attempts = 3) {
  return withRetry(() => fetch(url).then((response) => response.json()), attempts);
}

export function getJSON(url: string) {
  return request(url);
}
`;

const retry = `export async function withRetry<T>(task: () => Promise<T>, attempts = 3): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      if (attempt >= attempts) throw error;
    }
  }
}
`;

// In path order, as `git diff` writes a patch: the tree's first batch (25 files) then holds whole
// folders, and the last folder lands below them. Round-robin order put later files into folders
// already on screen, rewriting the visible rows after the first paint (a load shift).
const many = Array.from({ length: 30 }, (_, index) => ({
  path: `src/area${String(index % 6).padStart(2, "0")}/module${index}.ts`,
  before: `export const value${index} = ${index};\nexport const keep${index} = true;\n`,
  after: `export const value${index} = ${index * 2};\nexport const keep${index} = true;\nexport const added${index} = "new";\n`,
})).sort((a, b) => (a.path < b.path ? -1 : 1));

// Small edits inside lines: the word-level marks (word-alt joins words split by a space).
const config = `export const config = {
  retries: 3,
  timeoutMs: 5000,
  baseURL: "https://api.example.com/v1",
  headers: { Accept: "application/json" },
};

export function describe(config: Config): string {
  return \`\${config.baseURL} (\${config.retries} retries)\`;
}
`;
const configAfter = `export const config = {
  retries: 5,
  timeoutMs: 15000,
  baseURL: "https://api.example.com/v2",
  headers: { Accept: "application/json", "User-Agent": "cmux" },
};

export function describeConfig(config: Config, verbose = false): string {
  return \`\${config.baseURL} (\${config.retries} retries\${verbose ? \`, \${config.timeoutMs} ms\` : ""})\`;
}
`;

// A bigger review: 120 files in eight packages, edits of every size, so the files panel scrolls,
// the change bars vary and the stats line up in tabular figures.
const review = Array.from({ length: 120 }, (_, index) => {
  const lines = 4 + (index % 9) * 3;
  const body = (changed: boolean) =>
    Array.from({ length: lines }, (_, k) =>
      changed && k % (2 + (index % 4)) === 0
        ? `export const item${index}_${k} = compute(${k}, { cache: true });`
        : `export const item${index}_${k} = compute(${k});`,
    ).join("\n") + "\n";
  return {
    path: `packages/pkg${String(index % 8).padStart(2, "0")}/src/feature${String(index).padStart(3, "0")}.ts`,
    before: index % 17 === 5 ? undefined : body(false),
    after: index % 23 === 7 ? undefined : body(true),
  };
});

// A rename with an edit, a pure rename, a binary change and a mode change, as `git diff` writes them.
const renamesAndBinary = `diff --git a/src/net/http.ts b/src/net/client-http.ts
similarity 88%
rename from src/net/http.ts
rename to src/net/client-http.ts
index 3b18e51..a1f3c2d 100644
--- a/src/net/http.ts
+++ b/src/net/client-http.ts
@@ -1,3 +1,3 @@
 export function request(url: string) {
-  return fetch(url);
+  return fetch(url, { credentials: "include" });
 }
diff --git a/docs/old-name.md b/docs/new-name.md
similarity 100%
rename from docs/old-name.md
rename to docs/new-name.md
diff --git a/assets/logo.png b/assets/logo.png
index 5f2c1a0..9e8d7b6 100644
Binary files a/assets/logo.png and b/assets/logo.png differ
diff --git a/scripts/release.sh b/scripts/release.sh
old mode 100644
new mode 100755
`;

// Lines far wider than the pane: the wrap toggle's case.
const longBefore = `export const query = { select: ["id", "name", "email", "createdAt"], where: { team: "core" }, orderBy: "createdAt", limit: 50 };
export const message = "short";
`;
const longAfter = `export const query = { select: ["id", "name", "email", "createdAt", "updatedAt", "lastSeenAt", "plan", "seats"], where: { team: "core", archived: false, region: { in: ["us-east-1", "eu-west-1"] } }, orderBy: [{ createdAt: "desc" }, { id: "asc" }], limit: 200 };
export const message = "A much longer message that keeps going well past the edge of any reasonable diff pane width so it must scroll or wrap";
`;

// One large file: 400 lines with edits spread through it, so several hunks and the gaps between them show.
const bigLines = Array.from({ length: 400 }, (_, k) => `  step${k}: () => run(${k}, { retries: ${k % 5} }),`);
const bigBefore = `export const steps = {\n${bigLines.join("\n")}\n};\n`;
const bigAfter = `export const steps = {\n${bigLines
  .map((line, k) =>
    k % 37 === 3
      ? line.replace("retries", "attempts")
      : k % 53 === 10
        ? `${line}\n  extra${k}: () => skip(${k}),`
        : line,
  )
  .join("\n")}\n};\n`;

function reviewComment(id: string, filePath: string, line: number, message: string) {
  return {
    id,
    filePath,
    side: "additions" as const,
    startLine: line,
    endLine: line,
    lineText: "",
    message,
    createdAt: "2026-11-07T00:00:00.000Z",
    updatedAt: "2026-11-07T00:00:00.000Z",
  };
}

export default diffPageEntry({
  id: "pages.diff",
  title: "Diff viewer",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: [
    "page:cmux.diff",
    "App.tsx",
    "diff-viewer/freshness.ts",
    "DiffToolbar.tsx",
    "BranchBasePicker.tsx",
    "diff-viewer/FileHeader.tsx",
    "diff-viewer/FilesSidebar.tsx",
    "diff-viewer/Loading.tsx",
    "diff-viewer/Toolbar.tsx",
    "diff-viewer/WorkerRenderOptionsSync.tsx",
    "diff-viewer/PlainEnglishView.tsx",
  ],
  variants: {
    "jump-file-overflow": {
      note: "Thirty changed files scroll under soft edges in the open jump-to-file palette (files list hidden).",
      files: many,
      play: async (ctx) => {
        // Jump to file shows while the files list is hidden (toolbar-model.ts jumpToFileShown).
        await ctx.waitFor(() => ctx.document.querySelector('#files-toggle[aria-pressed="true"]'), { capMs: 10_000 });
        await ctx.click({ selector: "#files-toggle" });
        await ctx.waitFor(() => ctx.document.querySelector("#jump-to-file-button"), { capMs: 10_000 });
        await ctx.click({ selector: "#jump-to-file-button" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".jump-palette-row").length === many.length);
      },
    },
    "branch-base-overflow": {
      note: "Forty suggested branch bases scroll below the search field with soft edges.",
      files: [{ path: "src/net/client.ts", before, after }],
      branchGroups: [
        {
          id: "suggested",
          label: "Suggested",
          rows: Array.from({ length: 40 }, (_, index) => ({
            ref: `feature/review-${String(index).padStart(2, "0")}`,
            label: `feature/review-${String(index).padStart(2, "0")}`,
          })),
        },
      ],
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".base-picker-button"), { capMs: 10_000 });
        await ctx.click({ selector: ".base-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".base-picker-row").length === 40);
      },
    },
    "committed-overflow": {
      note: "Forty commits scroll in the Committed submenu while the source menu stays open.",
      files: [{ path: "src/net/client.ts", before, after }],
      sourceOptions: Array.from({ length: 40 }, (_, index) => ({
        value: `commit:${index.toString(16).padStart(40, "0")}`,
        label: `Commit ${String(index).padStart(2, "0")}: refine file search`,
        url: `/__gallery/commit/${index}`,
      })),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".source-pill-button"), { capMs: 10_000 });
        await ctx.click({ selector: ".source-pill-button" });
        await ctx.hover({ selector: '.toolbar-submenu-anchor > [aria-haspopup="menu"]' });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".toolbar-submenu .menu-item").length === 40);
      },
    },
    "cloud-offline": {
      note: "The loaded Cloud diff stays visible with its machine's offline reason.",
      title: "Build VM changes",
      fingerprintError: {
        code: "cmux.diff.machine_offline",
        message: "Build VM is offline. Reconnect to see its diff.",
      },
      files: [{ path: "src/net/client.ts", before, after }],
      play: async (ctx) => {
        await ctx.waitFor(
          () => ctx.document.querySelector(".file-header") && ctx.document.querySelector(".diff-files-changed"),
          { capMs: 10_000 },
        );
      },
    },
    loading: {
      note: "The diff has not arrived yet: the skeleton.",
      mode: "loading",
      files: [{ path: "src/net/client.ts", before, after }],
    },
    error: {
      note: "Opening the diff failed.",
      mode: "error",
      files: [{ path: "src/net/client.ts", before, after }],
    },
    "no-changes": {
      note: "The source has no changes.",
      patch: "",
    },
    "renamed-binary": {
      note: "A rename with an edit, a pure rename, a binary file and a mode change.",
      patch: renamesAndBinary,
    },
    "long-lines": {
      note: "Lines wider than the pane, unified.",
      layout: "unified",
      files: [{ path: "src/db/query.ts", before: longBefore, after: longAfter }],
    },
    "large-file": {
      note: "One 400-line file with edits spread through it: several hunks and the gaps between them.",
      height: 760,
      files: [{ path: "src/pipeline/steps.ts", before: bigBefore, after: bigAfter }],
    },
    "small-split": {
      note: "Two files, split layout: one changed, one added.",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
    },
    "density-compact": {
      note: "The same change at Compact: the toolbar, the file bars and the files list draw at the density's size, the code at its own (diff-viewer/density.ts).",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
      play: async (ctx) => {
        // As the host's scale script does: the density on the root, then the change event.
        await pageDensityPlay(pageDensities.find((density) => density.name === "compact")!.scale)(ctx);
        ctx.document.defaultView?.dispatchEvent(new Event("cmux-ui-scale-change"));
        await ctx.waitFor(() => ctx.document.querySelector(".file-header"), { capMs: 10_000 });
      },
    },
    unified: {
      note: "The same change, unified layout.",
      layout: "unified",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
    },
    deleted: {
      note: "A deleted file.",
      files: [{ path: "src/net/legacy.ts", before }],
    },
    "many-files": {
      note: "Thirty files in six folders (the file tree).",
      files: many,
    },
    "viewed-progress-menu": {
      note: 'Three of thirty files viewed: the "..." menu\'s Hide viewed files row says "3 of 30 viewed" (shipped).',
      files: many,
      play: async (ctx) => {
        await markThreeViewed(ctx);
        await ctx.click({ selector: "#options-button" });
        await ctx.waitFor(
          () => ctx.document.querySelector("#hide-viewed-toggle .menu-detail")?.textContent?.includes("30"),
          { capMs: 10_000 },
        );
      },
    },
    "viewed-progress-tooltip": {
      note: 'Three of thirty files viewed: the source pill\'s tooltip reads "Branch: +59 -29 · 3 of 30 files viewed" (shipped).',
      files: many,
      play: async (ctx) => {
        await markThreeViewed(ctx);
        await ctx.hover({ selector: "#source-menu .source-pill-stats" });
        await ctx.waitFor(() => ctx.document.querySelector(".ui-title-tooltip")?.textContent?.includes("30"), {
          capMs: 10_000,
        });
      },
    },
    "viewed-progress-suffix": {
      note: 'The pill-suffix arm (not shipped): the source pill shows "· 3/30" after its counts.',
      files: many,
      experiments: { "diff-viewed-progress": "suffix" },
      play: async (ctx) => {
        await markThreeViewed(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".source-pill-progress")?.textContent?.includes("/30"), {
          capMs: 10_000,
        });
      },
    },
    "word-diff": {
      note: "Edits inside lines, unified: the changed words are marked (on by default).",
      layout: "unified",
      files: [{ path: "src/net/config.ts", before: config, after: configAfter }],
    },
    "word-diff-split": {
      note: "The same edits side by side.",
      files: [{ path: "src/net/config.ts", before: config, after: configAfter }],
    },
    "big-review": {
      note: "120 files in eight packages: the files panel, its accent selection, change bars per file.",
      height: 760,
      layout: "unified",
      files: review,
    },
    "review-comments": {
      note: "Two saved review comments with Send to agent in the Comments section (hq #7563).",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
      commentsSend: true,
      comments: [
        reviewComment("r1", "src/net/client.ts", 3, "Three attempts is low for uploads; take it from config."),
        reviewComment("r2", "src/net/retry.ts", 5, "Back off between attempts instead of retrying at once."),
      ],
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("#comments-send"), { capMs: 10_000 });
      },
    },
    "review-from-link": {
      note: "A review worktree (cmux git review start <url>): the agent's drafts, Post to GitHub, and the pull request's line with Send to agent.",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
      commentsSend: true,
      commentsReview: {
        url: "https://github.com/acme/net/pull/482",
        repo: "acme/net",
        number: 482,
        title: "Retry uploads with backoff",
        head: "4f1c2e9",
        base: "9a0b3d1",
      },
      comments: [
        reviewComment("r1", "src/net/client.ts", 3, "Three attempts is low for uploads; take it from config."),
        reviewComment("r2", "src/net/retry.ts", 5, "Back off between attempts instead of retrying at once."),
      ],
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("#comments-post"), { capMs: 10_000 });
      },
    },
    "plain-english": {
      note: "Plain English on: each hunk is one sentence an agent wrote, its code folded beneath. Sentences arrive in place while the first changed line holds the row, so nothing moves.",
      height: 640,
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
        { path: "src/config.ts", before: config, after: configAfter },
      ],
      summaries: {
        delayMs: 300,
        sentences: {
          // The first key a hunk's patch contains names its sentence: the helper's own file first.
          "attempt >= attempts": "Adds a helper that reruns a failing task until it runs out of attempts.",
          withRetry: "Retries each request up to three times before giving up.",
          "retries: 5": "Raises retries to five, the timeout to 15 seconds, and moves to the v2 API.",
          describeConfig: "Renames describe to describeConfig and can add the timeout to its text.",
        },
      },
      play: async (ctx) => {
        await turnOnPlainEnglish(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll('.plain-english-row[data-state="ready"]').length >= 3, {
          capMs: 10_000,
        });
      },
    },
    "plain-english-open-hunk": {
      note: "One click unfolds a hunk's code under its sentence; Open in diff goes back to it in the full diff.",
      height: 640,
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
      summaries: {
        sentences: {
          // The first key a hunk's patch contains names its sentence: the helper's own file first.
          "attempt >= attempts": "Adds a helper that reruns a failing task until it runs out of attempts.",
          withRetry: "Retries each request up to three times before giving up.",
        },
      },
      play: async (ctx) => {
        await turnOnPlainEnglish(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('.plain-english-row[data-state="ready"]'), {
          capMs: 10_000,
        });
        await ctx.click({ selector: ".plain-english-row" });
        await ctx.waitFor(() => ctx.document.querySelector(".plain-english-code"), { capMs: 10_000 });
      },
    },
    "plain-english-many-files": {
      note: "Thirty files read as a page: only the rows on screen or a screen away ask for a sentence; the rest keep their code preview.",
      files: many,
      summaries: {
        delayMs: 150,
        sentences: { "export const added": "Doubles the value and adds a new string export." },
      },
      play: async (ctx) => {
        await turnOnPlainEnglish(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('.plain-english-row[data-state="ready"]'), {
          capMs: 10_000,
        });
      },
    },
    "plain-english-unavailable": {
      note: "No agent here can write summaries: the menu's Plain English row is off, and its tooltip says why.",
      files: [{ path: "src/net/client.ts", before, after }],
      summaries: { refused: "complete.not_installed" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("#options-button"), { capMs: 10_000 });
        await ctx.click({ selector: "#options-button" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-option="plain-english"][aria-disabled="true"]'), {
          capMs: 10_000,
        });
        await ctx.hover({ selector: '[data-option="plain-english"]' });
      },
    },
    "review-brief": {
      note: "An agent's diff with the chat's brief open: its goal, the spot it undid and redid and its hedge, the approach it dropped. A spot opens its hunk.",
      height: 640,
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/retry.ts", after: retry },
      ],
      reviewBrief: {
        sessionId: "gallery",
        seq: 42,
        brief: {
          goal: "Make requests retry with a bounded number of attempts, and keep getJSON's signature.",
          planText: "",
          plan: [
            { content: "Find where requests are sent", status: "completed" },
            { content: "Add withRetry", status: "completed" },
            { content: "Back off between attempts", status: "pending" },
          ],
          rejected: [
            {
              text: "Retrying inside getJSON didn't work because request() is called directly in two places.",
              seq: 12,
            },
          ],
          unsure: [
            {
              kind: "redone",
              path: "src/net/client.ts",
              snippet: "return withRetry(() => fetch(url).then((response) => response.json()), attempts);",
              seq: 20,
            },
            {
              kind: "hedge",
              text: "I'm not sure three attempts is right for uploads; it may need to come from config.",
              path: "src/net/client.ts",
              seq: 31,
            },
            {
              kind: "hedge",
              text: "withRetry is untested against a rejected promise that never settles.",
              path: "src/net/retry.ts",
              seq: 31,
            },
          ],
        },
      },
      play: async (ctx) => {
        const row = () => ctx.document.querySelector<HTMLButtonElement>(".review-brief-row:not(:disabled)");
        await ctx.waitFor(row, { capMs: 10_000 });
        row()?.click();
        await ctx.waitFor(() => ctx.document.querySelector('.review-brief[data-open="true"]'), { capMs: 5_000 });
      },
    },
    "collapsed-files": {
      note: "Three files, the first collapsed from its header: the bar stays, its chevron turns.",
      layout: "unified",
      files: [
        { path: "src/net/client.ts", before, after },
        { path: "src/net/config.ts", before: config, after: configAfter },
        { path: "src/net/retry.ts", after: retry },
      ],
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".file-header"), { capMs: 10_000 });
        await ctx.click({ selector: ".file-header" });
        await ctx.waitFor(() => ctx.document.querySelector('.file-header[data-collapsed="true"]'));
      },
    },
  },
});
