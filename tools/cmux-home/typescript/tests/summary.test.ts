import { describe, expect, test } from "bun:test";
import { renderSummary } from "../src/summary";
import { parseHomeState } from "../src/state";

describe("summary output", () => {
  test("prints deterministic once output", () => {
    const state = parseHomeState({
      sessions: [
        {
          agent: "codex",
          sessionId: "codex-1",
          status: "working",
          title: "Build home",
          cwd: "/repo",
        },
        {
          agent: "claude",
          sessionId: "claude-1",
          status: "awaiting",
          title: "Review plan",
          branch: "feat-home",
        },
      ],
    });

    expect(renderSummary(state)).toBe(`cmux home
sessions: total=2
adapters: claude=1 codex=1 opencode=0 pi=0
statuses: awaiting=1 working=1 completed=0

awaiting:
- claude/claude-1 "Review plan" branch=feat-home resume="claude --resume claude-1" gaps=2

working:
- codex/codex-1 "Build home" cwd=/repo resume="cd /repo && codex resume codex-1" gaps=2

task prompt: describe the next task for an agent
`);
  });
});
