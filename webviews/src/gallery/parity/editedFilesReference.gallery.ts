// l10n-allow-file: gallery fixture paths and text, not shipped UI.
import { agentPaneEntry } from "../format";
import { activity, assistant, chat, CWD, summary, tool, user } from "../fixtures/acpmux";

const paths: [string, number, number][] = [
  ["Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/CornerFlushTests.swift", 13, 0],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFClipShape.swift", 2, 2],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CornerFlush.swift", 10, 2],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CornerMetrics.swift", 26, 0],
  ["Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/CEFClipTests.swift", 18, 1],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextDesign/WindowCorners.swift", 17, 0],
  ["Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/WindowCornersTests.swift", 16, 0],
  ["Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/BrowserFrame.swift", 15, 0],
  ["webviews/test/window-corners.test.ts", 12, 0],
];

const files = paths.map(([path, additions, deletions]) => ({
  path,
  canonical: `${CWD}/${path}`,
  oldText: "unchanged\n" + Array.from({ length: deletions }, (_, index) => `removed ${index}\n`).join(""),
  newText: "unchanged\n" + Array.from({ length: additions }, (_, index) => `added ${index}\n`).join(""),
}));

export const referenceEditRow = activity(
  files.map((file) =>
    tool(`Edit ${file.path}`, "edit", "completed", {
      diffs: [file],
    }),
  ),
  0.8,
  { id: "parity-nine-files-edits", ended: true },
);

const twoFileRow = activity(
  files.slice(0, 2).map((file) => tool(`Edit ${file.path}`, "edit", "completed", { diffs: [file] })),
  0.8,
  { id: "parity-two-files-edits", ended: true },
);
const twoFileSnapshot = chat(
  [
    user("Review the two corner files.", 1),
    twoFileRow,
    assistant("The corner files are ready.", 0.75, { assistantPhase: "final_answer" }),
    summary(0.75, { id: "parity-two-files-summary", status: "completed", durationMs: 15_000 }),
  ],
  { harness: "codex", model: "gpt-5-codex" },
);
const twoFileNative = {
  "turn.undo": (params: unknown) => ({
    files: files.slice(0, 2).map((file) => ({
      path: file.canonical,
      status: (params as { apply?: boolean })?.apply ? "reverted" : "wouldRevert",
    })),
  }),
};

export default agentPaneEntry({
  id: "agent-pane.parity-edited-files",
  title: "Edited nine files, reference card",
  area: "Agent pane",
  height: 680,
  covers: ["agent-session/acpmux/conversation/EditedFilesCard.tsx"],
  variants: {
    "two-files": {
      note: "Two nested paths, a document-diff tile, aggregate counts and real Undo / View changes actions.",
      snapshot: twoFileSnapshot,
      native: twoFileNative,
    },
    "two-files-focus": {
      note: "Keyboard focus on aggregate counts exposes View changes and its external arrow without moving the header actions.",
      snapshot: twoFileSnapshot,
      native: twoFileNative,
      play: async (ctx) => {
        await ctx.focus({ selector: ".acpmux-edited-summary" });
        await ctx.waitFor(() => {
          const label = ctx.document.querySelector(".acpmux-edited-summary-link");
          return label && ctx.document.defaultView?.getComputedStyle(label).opacity === "1";
        });
      },
    },
    "nine-files": {
      note: "The reference card: Edited 9 files, +129 −5, three initial rows, Show 6 more files, Undo and View changes.",
      snapshot: chat(
        [
          user("Keep the window corners flush.", 1),
          referenceEditRow,
          assistant("The corner changes are ready.", 0.75, { assistantPhase: "final_answer" }),
          summary(0.75, { id: "parity-nine-files-summary", status: "completed", toolCount: 9, durationMs: 15_000 }),
        ],
        { harness: "codex", model: "gpt-5-codex" },
      ),
      native: {
        "turn.undo": (params: unknown) => ({
          files: files.map((file) => ({
            path: file.canonical,
            status: (params as { apply?: boolean })?.apply ? "reverted" : "wouldRevert",
          })),
        }),
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-edited-file").length === 3);
        const card = ctx.document.querySelector(".acpmux-edited")!;
        if (!card.querySelector(".acpmux-edited-title")?.textContent?.includes("Edited 9 files"))
          throw new Error("Missing nine-file title");
        if (card.querySelector(".acpmux-edited-more")?.textContent?.trim() !== "Show 6 more files")
          throw new Error("Missing six-file expansion");
        if (!card.querySelector(".acpmux-edited-undo") || !card.querySelector(".acpmux-review-changes"))
          throw new Error("Missing reference card actions");
      },
    },
  },
});
