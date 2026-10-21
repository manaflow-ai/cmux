// l10n-allow-file: gallery fixtures (sample Run and attempt evidence), not shipped UI.
import { activity, assistant, tool, user } from "../../../gallery/fixtures/acpmux";
import type { RunArtifact, RunAttempt, RunBoardSnapshot } from "./model";

const artifacts = (id: string): RunArtifact[] => [
  { id: `${id}-screen`, name: "workspace.png", kind: "screenshot", digest: `fixture-${id}-screen`, verified: true },
  { id: `${id}-video`, name: "walkthrough.webm", kind: "recording", digest: `fixture-${id}-video`, verified: true },
  { id: `${id}-patch`, name: "implementation.patch", kind: "patch", digest: `fixture-${id}-patch`, verified: true },
];

const attempt = (id: string, label: string, direction: string, worker: string, completed: boolean): RunAttempt => ({
  id,
  label,
  direction,
  worker,
  sessionId: `session-${id.slice(-1)}`,
  state: completed ? "completed" : "running",
  activity: completed
    ? "Walkthrough recorded. Ready for your review."
    : "Refining the narrow layout and capturing the walkthrough.",
  build: completed ? "passed" : "pending",
  tests: { passed: completed ? 28 : 24, failed: 0 },
  artifacts: completed ? artifacts(id) : [],
  rows: [
    user("Explore a calmer workspace home. Work independently from the shared intent.", 18),
    assistant(
      `I’m exploring ${direction.toLowerCase()}. I reused the shared navigation and typography components.`,
      16,
    ),
    activity(
      [
        tool("Updated workspace layout", "edit", "completed", {
          diffs: [
            { path: "src/workspace/Workspace.tsx", newText: "export function Workspace() {}" },
            { path: "src/workspace/styles.css", newText: ".workspace { display: grid; }" },
          ],
        }),
        tool("Build and interaction tests", "execute", completed ? "completed" : "running", {
          command: "bun run build && bun test workspace",
          output: completed
            ? "Build passed\n28 tests passed · 0 failed\nRecording and artifact manifest published"
            : "24 tests passed\nChecking the compact layout…",
          exitCode: completed ? 0 : undefined,
        }),
      ],
      8,
    ),
    assistant(
      completed
        ? "The UI and recording are ready. The strongest tradeoff is a quieter starting point with a little less information visible at once."
        : "The main layout is working. I’m testing keyboard navigation before I publish the final evidence.",
      3,
    ),
  ],
});

export const runBoardFixture: RunBoardSnapshot = {
  id: "run_7f2a",
  title: "Find a better workspace home",
  intent:
    "Help people see what needs attention and get back into their work quickly. Build a working UI, reuse the existing system, and record the real interaction.",
  source: "atlas / ui-exploration @ 9b2f4c1",
  cursor: "143",
  attempts: [
    attempt("attempt-a", "Attempt A", "Overview + project cards", "cloud-vm · workspace-a", true),
    attempt("attempt-b", "Attempt B", "Quiet, focus-first canvas", "cloud-vm · workspace-b", true),
    attempt("attempt-c", "Attempt C", "Dense, keyboard-first list", "cloud-vm · workspace-c", false),
    {
      ...attempt("attempt-d", "Attempt D", "Activity-led workspace", "cloud-vm · workspace-d", false),
      state: "failed",
      build: "failed",
      tests: { passed: 23, failed: 1 },
      activity: "Keyboard focus test failed. The attempt and its logs are preserved.",
    },
  ],
};

export const replayedBoardFixture: RunBoardSnapshot = {
  ...runBoardFixture,
  cursor: "151",
  attempts: runBoardFixture.attempts.map((item) =>
    item.id === "attempt-c"
      ? {
          ...item,
          state: "completed",
          build: "passed",
          tests: { passed: 30, failed: 0 },
          artifacts: artifacts(item.id),
          activity: "Finished while you were disconnected. All evidence recovered.",
        }
      : item,
  ),
};
