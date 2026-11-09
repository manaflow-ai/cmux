// l10n-allow-file: gallery fixtures, public-safe sample chats and files.
import type { ComponentProps } from "react";
import { minutesAgo } from "../../../gallery/clock";
import { session } from "../../../gallery/fixtures/acpmux";
import { componentEntry } from "../../../gallery/format";
import type { ReviewScreen } from "./ReviewScreen";

type Props = ComponentProps<typeof ReviewScreen>;

/// Three agents in three worktrees finished their edits; a fourth still works.
const sessions = [
  session({
    sessionId: "review-a",
    title: "Add retry to the upload client",
    worktree: "/work/app-upload-retry",
    branch: "lane/upload-retry",
    activityAt: minutesAgo(2),
    lastMessage: "Uploads now retry three times with backoff; the tests cover a dropped connection.",
    pullRequest: { number: 412, title: "Upload retry", state: "open", checks: "passing" },
  }),
  session({
    sessionId: "review-b",
    title: "Fix the settings search ranking",
    worktree: "/work/app-settings-search",
    branch: "lane/settings-search",
    harness: "codex",
    activityAt: minutesAgo(9),
    lastMessage: "Exact title matches rank first now, then keywords.",
  }),
  session({
    sessionId: "review-c",
    title: "Document the export command",
    worktree: "/work/app-export-docs",
    branch: "lane/export-docs",
    activityAt: minutesAgo(24),
    lastMessage: "Added a usage section and two examples to the CLI reference.",
    pullRequest: { number: 409, title: "Export docs", state: "open", checks: "failing" },
  }),
  session({
    sessionId: "review-d",
    title: "Speed up the file index",
    worktree: "/work/app-file-index",
    branch: "lane/file-index",
    activityAt: minutesAgo(1),
    lane: "working",
    lastMessage: "Measuring the cold start with the new cache.",
  }),
];

const files: Record<string, { path: string; additions: number; deletions: number }[]> = {
  "/work/app-upload-retry": [
    { path: "src/upload/client.ts", additions: 48, deletions: 6 },
    { path: "src/upload/client.test.ts", additions: 61, deletions: 0 },
  ],
  "/work/app-settings-search": [
    { path: "src/settings/search.ts", additions: 12, deletions: 9 },
    { path: "src/settings/rank.ts", additions: 20, deletions: 3 },
    { path: "src/settings/rank.test.ts", additions: 33, deletions: 0 },
    { path: "src/settings/fixtures.json", additions: 4, deletions: 1 },
  ],
  "/work/app-export-docs": [{ path: "docs/cli/export.md", additions: 57, deletions: 2 }],
  "/work/app-file-index": [{ path: "src/index/cache.ts", additions: 88, deletions: 14 }],
};

const readDiff: Props["readDiff"] = async (cwd) => {
  const list = files[cwd] ?? [];
  return {
    scope: "branch",
    head: "1111111111111111111111111111111111111111",
    files: list.map((file) => ({ ...file, status: "modified" })),
    additions: list.reduce((sum, file) => sum + file.additions, 0),
    deletions: list.reduce((sum, file) => sum + file.deletions, 0),
    total_files: list.length,
  };
};

const done = async () => undefined;
const base: Props = { sessions, readDiff, openDiff: done, accept: done, send: done };

export default componentEntry<Props>({
  id: "agent-pane.review-changes",
  title: "Review queue",
  area: "Agent pane",
  covers: ["agent-session/acpmux/review/ReviewScreen.tsx#ReviewScreen"],
  styles: () => Promise.all([import("../styles.css"), import("../keys.css"), import("./review.css")]),
  load: () => import("./ReviewScreen").then((module) => module.ReviewScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 520,
  anchors: [{ selector: ".rv" }],
  variants: {
    detail: {
      note: "The shipped look: each folder's change and the turn that made it, needing you first.",
      props: base,
    },
    compact: {
      note: "Alternative: one line per folder, the densest queue.",
      props: { ...base, look: "compact" },
    },
    files: {
      note: "Alternative: the detail rows with each folder's first files.",
      props: { ...base, look: "files" },
    },
    "request-changes": {
      note: "r on the first row: the comment Return sends to that folder's chat.",
      props: { ...base, initialComment: "/work/app-upload-retry" },
    },
    reading: {
      note: "The folders' changes are still being read: the status line holds the list's place.",
      props: { ...base, readDiff: () => new Promise(() => {}) },
    },
    empty: {
      note: "Every folder is reviewed or clean.",
      props: { ...base, readDiff: async () => ({ scope: "branch", files: [] }) },
    },
  },
});
