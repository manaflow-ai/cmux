// A slash command sent as the prompt's first word (`/compact`, `/goal ship it`, `/loop 5m check`)
// keeps the composer's command rendering in the transcript: the composer lights a `/name` that
// names any command at the prompt's start (composer/slashTokens.ts, slashCommands.ts slashNames
// `leading`), so the sent row lights the same word with the same SkillWord blue (Leo 2026-11-09:
// "these commands after i send them off should preserve their special rendering").
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const COMMANDS = [
  { name: "compact", description: "Clear the history but keep a summary", source: "agent" as const },
  { name: "goal", description: "Set a goal", source: "agent" as const },
  { name: "loop", description: "Run a prompt on an interval", source: "agent" as const },
  { name: "review-pr", description: "Review a pull request", source: "skill" as const },
];

async function bubble(text: string) {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { SkillWordsContext, skillWords } = await import("../src/agent-session/acpmux/conversation/skillWords");
  root ??= createRoot(host);
  const row = { id: "user-1", version: 1, at: 0, kind: "user" as const, seq: 1, text };
  act(() =>
    root!.render(
      <SkillWordsContext.Provider value={skillWords(COMMANDS)}>
        <UserBubble row={row} text={text} />
      </SkillWordsContext.Provider>,
    ),
  );
  return [...host.querySelectorAll<HTMLElement>(".cv-skill-word")].map((word) => word.textContent);
}

test("a sent /compact draws as the composer's command word, not plain text", async () => {
  expect(await bubble("/compact")).toEqual(["/compact"]);
  expect(host.querySelector(".cv-user__bubble")!.textContent).toBe("/compact");
});

test("a command with arguments lights only the command; the arguments stay text", async () => {
  expect(await bubble("/goal ship the release")).toEqual(["/goal"]);
  expect(host.querySelector(".cv-user__bubble")!.textContent).toBe("/goal ship the release");
  expect(await bubble("\n  /loop 5m check the deploy")).toEqual(["/loop"]);
});

test("as in the composer, a built-in command counts only as the prompt's first word", async () => {
  expect(await bubble("please /compact now")).toEqual([]);
  expect(await bubble("/nope at the start")).toEqual([]);
  expect(await bubble("/goal then /review-pr and /compact")).toEqual(["/goal", "/review-pr"]);
  expect(await bubble("`/compact` is code")).toEqual([]);
});

test("a Markdown prompt led by a command lights it; a later built-in of another name stays plain", async () => {
  expect(await bubble("/goal fix `foo` and **ship** it, then /compact")).toEqual(["/goal"]);
  expect(host.querySelector(".cv-user__bubble code")?.textContent).toBe("foo");
});

test("a prompt with an inspector pick still lights the command it starts with", async () => {
  const { UI_PICK_HEADER } = await import("../src/agent-session/acpmux/composer/uiPickModel");
  const pick = `UI: span\n\`\`\`\n${UI_PICK_HEADER}\nselector: span\n\`\`\``;
  expect(await bubble(`/goal fix this\n${pick}`)).toEqual(["/goal"]);
  expect(await bubble(`${pick}\n/goal fix this`)).toEqual(["/goal"]);
  expect(await bubble(`fix this\n${pick}\n/goal`)).toEqual([]);
});

test("the split reads the lead word against every command, later words against skills only", async () => {
  const { splitSkillWords, skillWords } = await import("../src/agent-session/acpmux/conversation/skillWords");
  const words = skillWords(COMMANDS);
  expect(splitSkillWords("/compact focus on tests /compact", words.words, words.leading)).toEqual([
    { word: "/compact", description: "" },
    " focus on tests /compact",
  ]);
});

test("a queued command draws as the sent one does", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const box = dom.window.document.createElement("div");
  dom.window.document.body.append(box);
  const queue = createRoot(box);
  await act(async () =>
    queue.render(
      <ComposerQueue
        queue={[
          { id: "q-1", prompt: "/loop 5m check the deploy" },
          { id: "q-2", prompt: "then /loop" },
        ]}
        chat="c"
        t={((key: string) => key) as never}
        commands={COMMANDS}
      />,
    ),
  );
  const lit = (id: string) =>
    [...box.querySelectorAll(`[data-prompt-id="${id}"] .cv-skill-word`)].map((word) => word.textContent);
  expect(lit("q-1")).toEqual(["/loop"]);
  expect(lit("q-2")).toEqual([]);
  await act(async () => queue.unmount());
  box.remove();
});
