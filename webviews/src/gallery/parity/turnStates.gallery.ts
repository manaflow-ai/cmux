// l10n-allow-file: focused gallery fixture prompts and labels, not shipped UI.
import { agentPaneEntry } from "../format";
import { minutesAgo } from "../clock";
import { activity, assistant, chat, summary, tool, user } from "../fixtures/acpmux";
import type { PlayContext } from "../play";

const prompt = user("Check the retry helper.", 1, { id: "parity-turn-prompt" });
const commentary = assistant("Checking its caller.", 0.95, {
  id: "parity-turn-commentary",
  assistantPhase: "commentary",
});
const read = activity([tool("Read retry.ts", "read", "completed")], 0.9, { id: "parity-turn-read" });
const work = [prompt, commentary, read];
const answer = assistant("The retry helper is correct.", 0.75, {
  id: "parity-turn-answer",
  assistantPhase: "final_answer",
});

async function visibleHeader(ctx: PlayContext, expected: RegExp): Promise<HTMLElement> {
  const find = () =>
    [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].find((node) => expected.test(node.textContent ?? ""));
  await ctx.waitFor(() => Boolean(find()));
  const header = find()!;
  const bounds = header.getBoundingClientRect();
  const viewport = ctx.document.defaultView!;
  if (bounds.width <= 0 || bounds.height <= 0 || bounds.top < 0 || bounds.bottom > viewport.innerHeight)
    throw new Error(
      `Work header is outside the visible fixture: ${JSON.stringify({ text: header.textContent, top: bounds.top, bottom: bounds.bottom, viewport: viewport.innerHeight })}`,
    );
  return header;
}

export default agentPaneEntry({
  id: "agent-pane.parity-turn-states",
  title: "Working and Worked for, in view",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/rows/WorkingRow.tsx", "agent-session/acpmux/rows/WorkedRow.tsx"],
  variants: {
    working: {
      note: "Short live turn: Working for stays visible above its activity, with the real composer below.",
      experiments: { "live-turn-clock": "top" },
      snapshot: chat(
        [
          ...work,
          activity(
            [
              tool("Run retry test", "execute", "in_progress", {
                command: "bun test retry",
                startedAt: minutesAgo(0.85),
              }),
            ],
            0.85,
            { id: "parity-turn-running" },
          ),
        ],
        { harness: "codex", model: "gpt-5-codex", isWorking: true },
      ),
      play: async (ctx) => {
        await visibleHeader(ctx, /Working for/);
      },
    },
    worked: {
      note: "Short completed turn: Worked for 15s and the final answer fit together without scrolling.",
      snapshot: chat(
        [
          ...work,
          answer,
          summary(0.75, {
            id: "parity-turn-summary",
            status: "completed",
            durationMs: 15_000,
            toolCount: 1,
          }),
        ],
        { harness: "codex", model: "gpt-5-codex" },
      ),
      play: async (ctx) => {
        await visibleHeader(ctx, /Worked for 15s/);
      },
    },
    "final-answer-streaming": {
      note: "Final answer is streaming: prior work folds, and its Worked for clock freezes at the first final answer (15s).",
      snapshot: chat([...work, { ...answer, streaming: true }], {
        harness: "codex",
        model: "gpt-5-codex",
        isWorking: true,
      }),
      play: async (ctx) => {
        await visibleHeader(ctx, /Worked for 15s/);
        await ctx.waitFor(() => Boolean(ctx.document.querySelector('.cv-worked[aria-expanded="false"]')));
      },
    },
    stopped: {
      note: "Short interrupted turn: the stopped work header and Continue remain in view.",
      snapshot: chat(
        [
          ...work,
          summary(0.75, {
            id: "parity-turn-stopped",
            status: "cancelled",
            durationMs: 15_000,
            toolCount: 1,
          }),
        ],
        { harness: "codex", model: "gpt-5-codex" },
      ),
      play: async (ctx) => {
        await visibleHeader(ctx, /You stopped after 15s/);
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll("button")].some((node) => node.textContent?.trim() === "Continue"),
        );
      },
    },
  },
});
