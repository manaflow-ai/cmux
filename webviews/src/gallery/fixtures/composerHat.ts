// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's tally fixtures and its promises, shared by the tally entry
// (ComposerHatTally.gallery.ts) and the width x state matrix (ComposerHatMatrix.gallery.ts).
import { activity, chat, row, user, tool } from "./acpmux";
import { minutesAgo, recentRun } from "../clock";
import type { PlayContext } from "../play";
import { SUBAGENTS, type Subagent } from "../../agent-session/acpmux/subagents/subagentFold";

function agent(task: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  return {
    id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state,
    background: true,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, Math.min(minutes, 4))),
    ...fields,
  };
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

/** Claude and Codex subagents, a test run and a server; one subagent done, one failed. */
export const mixed = chat(
  [
    user("Review the tray from both sides and keep the tests going", 12),
    row(SUBAGENTS, 12, {
      subagents: [
        agent("Review the tray columns", 9, "running"),
        agent("Review the header counts", 8, "running"),
        agent("Cross-check the counts", 7, "running", { harness: "codex" }),
        agent("Find the screenshot", 11, "completed"),
        agent("Bisect the flaky fold test", 10, "failed"),
      ],
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 7),
        command("cd ~/Projects/app/webviews && bun test --watch", "Watch the tests", 3),
      ],
      7,
    ),
  ],
  { isWorking: true },
);

/** One background command, alone: counted as several are, never "Running a command". */
export const lone = chat(
  [
    user("Watch the nightly", 3),
    activity([command("gh run watch 41723867191 --exit-status", "Wait for the nightly run", 2.5)], 3),
  ],
  { isWorking: true },
);

/** Twenty subagents over three harnesses and six commands of four kinds, at any width. */
export const burst = chat(
  [
    user("Fan out over every package", 20),
    row(SUBAGENTS, 20, {
      subagents: Array.from({ length: 20 }, (_, index) =>
        agent(`Audit package ${index + 1}`, 19 - index * 0.5, "running", {
          harness: ["claude", "codex", "gemini"][index % 3]!,
        }),
      ),
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 15),
        command("bun test --watch", "Watch the tests", 14),
        command("swift build -c release --product App", "Compile the head", 6),
        command("gh pr checks 34260 --watch", "Wait for the checks", 5),
        command("gh run watch 41723867191", "Wait for the nightly", 4),
        command("python3 scripts/check-test-determinism.py --runs 20", "Check test determinism", 3),
      ],
      15,
    ),
  ],
  { isWorking: true },
);

/** Twelve: eight subagents over three harnesses and four commands, the middle of the count matrix. */
export const twelve = chat(
  [
    user("Split the review across the harnesses", 14),
    row(SUBAGENTS, 14, {
      subagents: Array.from({ length: 8 }, (_, index) =>
        agent(`Review part ${index + 1}`, 13 - index, "running", {
          harness: ["claude", "codex", "gemini"][index % 3]!,
        }),
      ),
    }),
    activity(
      [
        command("bun test --watch", "Watch the tests", 12),
        command("swift build -c release --product App", "Compile the head", 6),
        command("gh pr checks 34260 --watch", "Wait for the checks", 5),
        command("gh run watch 41723867191", "Wait for the nightly", 4),
      ],
      12,
    ),
  ],
  { isWorking: true },
);

/** Only finished, fine work: nothing to count, so the header keeps its own. */
export const settled = chat(
  [user("Find the screenshot", 6), row(SUBAGENTS, 6, { subagents: [agent("Find the screenshot", 5, "completed")] })],
  { isWorking: true },
);

export const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

/** The tally's promises, at whatever width the stage has. */
export function tallyHolds(ctx: PlayContext, minKinds: number): void {
  const header = head(ctx)!;
  const kinds = header.querySelector<HTMLElement>(".acpmux-running-tray__kinds[data-tally]");
  if (!kinds) throw new Error("no tally header");
  if (/running/i.test(header.textContent ?? "")) throw new Error(`the header says running: ${header.textContent}`);
  if (header.querySelector(".acpmux-running-tray__kind-sep, .acpmux-running-tray__latest"))
    throw new Error("the tally draws no separators and no step words");
  const row = kinds.getBoundingClientRect();
  const shown = [...kinds.querySelectorAll<HTMLElement>(".acpmux-running-tray__kind")].filter(
    (kind) => kind.getBoundingClientRect().top < row.bottom - 0.5,
  );
  if (shown.length < minKinds) throw new Error(`${shown.length} kinds shown, wanted ${minKinds}`);
  for (const kind of shown) {
    const box = kind.getBoundingClientRect();
    // Whole or not at all: no kind cut at the row's end, none into an ellipsis.
    if (box.right > row.right + 0.5) throw new Error(`${kind.dataset.kind} is cut at the row's end`);
    if (!/^\d+$/.test(kind.textContent ?? "")) throw new Error(`${kind.dataset.kind} reads "${kind.textContent}"`);
  }
  const time = header.querySelector<HTMLElement>(".acpmux-running-tray__time");
  if (time && time.scrollWidth > time.clientWidth + 0.5) throw new Error("the time is clipped");
}

/** Nothing ongoing: the composer alone, no hat. */
export const idle = chat([user("Find the screenshot", 6)], { isWorking: false });

/** A draft eight lines tall: the composer grown well past one line. */
export const GROWN_DRAFT = Array.from(
  { length: 8 },
  (_, line) => `Line ${line + 1}: and keep the hat's counts whole when the pane is narrow`,
).join("\n");

/** The dock's promises at whatever width the stage has: the hat sits above the composer, never over
 *  it; nothing runs wider than the pane; the composer's buttons stay on its bottom edge. */
export function dockHolds(ctx: PlayContext, modelPicker: string): void {
  const doc = ctx.document;
  const pane = doc.documentElement.getBoundingClientRect();
  const box = doc.querySelector<HTMLElement>(".acpmux-composer-box");
  if (!box) throw new Error("no composer");
  const boxRect = box.getBoundingClientRect();
  const hat = head(ctx);
  if (hat) {
    const hatRect = hat.getBoundingClientRect();
    if (hatRect.bottom > boxRect.top + 0.5) throw new Error("the hat overlaps the composer");
    if (hatRect.right > pane.right + 0.5) throw new Error("the hat runs wider than the pane");
  }
  if (boxRect.right > pane.right + 0.5) throw new Error("the composer runs wider than the pane");
  const picker = doc.querySelector<HTMLElement>(modelPicker);
  if (picker && boxRect.bottom - picker.getBoundingClientRect().bottom > 24)
    throw new Error("the composer's buttons left its bottom edge");
}
