import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { restoredDecisions, type HunkDecision, type HunkReview } from "../changes/hunkReview";
import type { AcpmuxRow } from "../model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { EditedFilesCard } = await import("./EditedFilesCard");
const { TurnFooter } = await import("./TurnRows");
const { TurnActionsContext } = await import("./turnActions");

const edited: AcpmuxRow = {
  id: "e",
  version: 1,
  at: 0,
  kind: "activity",
  ended: true,
  items: [
    {
      kind: "tool",
      text: "Edit summarize_run.py",
      tool: {
        id: "t1",
        title: "Edit summarize_run.py",
        kind: "edit",
        status: "completed",
        diffs: [{ path: "/repo/summarize_run.py", oldText: "a\nb\n", newText: "a\nB\nc\n" }],
      },
    },
  ],
};

async function render(
  element: ReturnType<typeof createElement>,
  actions: Parameters<typeof TurnActionsContext.Provider>[0]["value"],
) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const draw = (value: typeof actions) =>
    act(async () => root.render(createElement(TurnActionsContext.Provider, { value }, element)));
  await draw(actions);
  return { container, draw, unmount: () => act(async () => root.unmount()) };
}

function review(decisions: Map<string, HunkDecision>, asked: { keys: string[]; prompt: string }[]): HunkReview {
  return { decisions, decide: () => {}, requestRevert: (keys, prompt) => asked.push({ keys, prompt }) };
}

describe("edited-files card", () => {
  test("reads like Codex's footer: the file, its counts, Undo and View changes", async () => {
    const asked: { keys: string[]; prompt: string }[] = [];
    const opened: (string | undefined)[] = [];
    const { container, draw, unmount } = await render(
      createElement(EditedFilesCard, { row: edited, onOpenDiff: (_row, path) => opened.push(path) }),
      { review: review(new Map(), asked) },
    );
    expect(container.querySelector(".acpmux-edited-title")!.textContent).toBe("Edited summarize_run.py+2-1");
    const buttons = [...container.querySelectorAll("button")].map((button) => button.textContent);
    expect(buttons).toEqual(["Undo", "View changes"]);

    const undo = container.querySelector<HTMLButtonElement>(".acpmux-edited-undo")!;
    await act(async () => undo.click());
    expect(asked).toHaveLength(1);
    expect(asked[0]!.keys).toHaveLength(1);
    expect(asked[0]!.prompt).toStartWith("Please undo the changes you made in that turn");
    expect(asked[0]!.prompt).toContain("--- /repo/summarize_run.py");

    // Once asked, the card says so and does not ask again.
    await draw({ review: review(new Map(asked[0]!.keys.map((key) => [key, "requested" as const])), asked) });
    const requested = container.querySelector<HTMLButtonElement>(".acpmux-edited-undo")!;
    expect(requested.textContent).toBe("Undo requested");
    expect(requested.disabled).toBe(true);

    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-review-changes")!.click());
    expect(opened).toEqual(["/repo/summarize_run.py"]);
    await unmount();
  });

  test("a hunk already sent from the changes view is left out of Undo", async () => {
    const asked: { keys: string[]; prompt: string }[] = [];
    const twoFiles: AcpmuxRow = {
      ...edited,
      items: [
        ...edited.items!,
        {
          kind: "tool",
          text: "Edit notes.md",
          tool: {
            id: "t2",
            title: "Edit notes.md",
            kind: "edit",
            status: "completed",
            diffs: [{ path: "/repo/notes.md", newText: "x\n" }],
          },
        },
      ],
    };
    const first = await render(createElement(EditedFilesCard, { row: twoFiles }), { review: review(new Map(), asked) });
    await act(async () => first.container.querySelector<HTMLButtonElement>(".acpmux-edited-undo")!.click());
    const [sentKey, otherKey] = asked[0]!.keys;
    await first.unmount();

    const again: typeof asked = [];
    const second = await render(createElement(EditedFilesCard, { row: twoFiles }), {
      review: review(new Map([[sentKey!, "requested"]]), again),
    });
    await act(async () => second.container.querySelector<HTMLButtonElement>(".acpmux-edited-undo")!.click());
    expect(again[0]!.keys).toEqual([otherKey!]);
    await second.unmount();
  });

  test("a turn still running shows its edits without Undo", async () => {
    const { container, unmount } = await render(createElement(EditedFilesCard, { row: { ...edited, ended: false } }), {
      review: review(new Map(), []),
    });
    expect(container.querySelector(".acpmux-edited-title")!.textContent).toBe("Edited summarize_run.py+2-1");
    expect(container.querySelector(".acpmux-edited-undo")).toBeNull();
    await unmount();
  });

  test("without the hunk review there is no Undo", async () => {
    const { container, unmount } = await render(
      createElement(EditedFilesCard, { row: edited, onOpenDiff: () => {} }),
      {},
    );
    expect(container.querySelector(".acpmux-edited-undo")).toBeNull();
    await unmount();
  });
});

describe("edited-files card Undo", () => {
  test("never asks the agent to undo: the agent could run git checkout and lose later edits", async () => {
    const asked: { keys: string[]; prompt: string }[] = [];
    const { container, unmount } = await render(createElement(EditedFilesCard, { row: edited, onOpenDiff: () => {} }), {
      review: review(new Map(), asked),
    });
    expect([...container.querySelectorAll("button")].map((button) => button.textContent)).toEqual(["View changes"]);
    expect(container.querySelector(".acpmux-edited-undo")).toBeNull();
    expect(asked).toEqual([]);
    await unmount();
  });
});

describe("turn footer", () => {
  const summary: AcpmuxRow = { id: "s", version: 1, at: 0, kind: "turnSummary", text: "Done.", folded: true };

  test("Retry sends the turn's prompt again", async () => {
    const sent: string[] = [];
    const { container, unmount } = await render(createElement(TurnFooter, { row: { ...summary, prompt: "fix it" } }), {
      retry: (prompt) => sent.push(prompt),
    });
    const retry = container.querySelector<HTMLButtonElement>('button[aria-label="Retry"]')!;
    expect(retry.title).toBe("Send this prompt again");
    await act(async () => retry.click());
    expect(sent).toEqual(["fix it"]);
    await unmount();
  });

  test("no Retry on an earlier turn, or while acpmux is unreachable", async () => {
    const earlier = await render(createElement(TurnFooter, { row: summary }), { retry: () => {} });
    expect(earlier.container.querySelector('button[aria-label="Retry"]')).toBeNull();
    await earlier.unmount();
    const offline = await render(createElement(TurnFooter, { row: { ...summary, prompt: "fix it" } }), {});
    expect(offline.container.querySelector('button[aria-label="Retry"]')).toBeNull();
    await offline.unmount();
  });
});

describe("a failed revert send", () => {
  test("puts back what the reader had decided, and leaves hunks decided since alone", () => {
    const current = new Map<string, HunkDecision>([
      ["rejected-before", "requested"],
      ["undecided-before", "requested"],
      ["accepted-since", "accepted"],
    ]);
    const restored = restoredDecisions(current, [
      ["rejected-before", "rejected"],
      ["undecided-before", undefined],
      ["accepted-since", undefined],
    ]);
    expect([...restored]).toEqual([
      ["rejected-before", "rejected"],
      ["accepted-since", "accepted"],
    ]);
  });
});
