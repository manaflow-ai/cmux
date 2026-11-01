// A skill's `/name` in a sent prompt draws in the composer's command blue, with the skill's
// description as the app's tooltip on hover (SkillWord.tsx, ui/titleTooltips.ts); a skill with no
// description is blue only, and a word that names no skill stays plain (Lucas 2026-11-02). The
// composer's own skill words carry the same tooltip (composer/slashTokens.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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

afterAll(() => {
  act(() => root?.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const VOCABULARY = "The precise design and UI vocabulary";
const COMMANDS = [
  { name: "init", description: "Create an AGENTS.md file", source: "agent" as const },
  { name: "$emil-design-vocabulary", description: VOCABULARY, source: "skill" as const },
  { name: "$emil-color", description: "", source: "skill" as const },
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
  return [...host.querySelectorAll<HTMLElement>(".cv-skill-word")];
}

test("skill words split out of a prompt's text at command positions only", async () => {
  const { splitSkillWords, skillWords } = await import("../src/agent-session/acpmux/conversation/skillWords");
  const { words } = skillWords(COMMANDS);
  expect(splitSkillWords("use /emil-color, then /review-pr now and src/review-pr /init", words)).toEqual([
    "use /emil-color, then ",
    { word: "/review-pr", description: "Review a pull request" },
    " now and src/review-pr /init",
  ]);
  expect(splitSkillWords("/emil-color", words)).toEqual([{ word: "/emil-color", description: "" }]);
});

test("in a bubble only skill words are blue; one with a description carries it as its tooltip", async () => {
  const words = await bubble("hello lets use /$emil-design-vocabulary and /$emil-color, keep /init and /nope");
  expect(words.map((word) => word.textContent)).toEqual(["/emil-design-vocabulary"]);
  const [vocabulary] = words;
  expect(vocabulary!.dataset.tooltip).toBe(VOCABULARY);
  expect(vocabulary!.getAttribute("aria-description")).toBe(VOCABULARY);
  expect(vocabulary!.dataset.tooltipSide).toBe("top");
  // `/emil-color,` runs into its comma: no skill word, as in the composer.
  const plain = await bubble("then /$emil-color for the palette");
  expect(plain.map((word) => word.textContent)).toEqual(["/emil-color"]);
  expect(plain[0]!.hasAttribute("data-tooltip")).toBe(false);
  expect(plain[0]!.hasAttribute("aria-description")).toBe(false);
});

test("a prompt written in Markdown draws its skill words too, never inside code", async () => {
  const words = await bubble("run `bun test` with `/review-pr`, then\n- ask /review-pr for a pass");
  expect(words.map((word) => word.textContent)).toEqual(["/review-pr"]);
  expect(host.querySelector("code")?.textContent).toBe("bun test");
});

test("the app's tooltip shows the description on hover", async () => {
  const { installTooltips } = await import("../src/ui/titleTooltips");
  const uninstall = installTooltips(dom.window.document, { delay: 0 });
  try {
    const [word] = await bubble("use /$emil-design-vocabulary here");
    word!.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    await act(async () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve())));
    const tip = dom.window.document.querySelector<HTMLElement>(".ui-title-tooltip")!;
    expect(tip.hidden).toBe(false);
    expect(tip.textContent).toBe(VOCABULARY);
  } finally {
    uninstall();
  }
});

test("a queued prompt draws its skill words as the bubble does", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const box = dom.window.document.createElement("div");
  dom.window.document.body.append(box);
  const queue = createRoot(box);
  await act(async () =>
    queue.render(
      <ComposerQueue
        queue={[{ id: "q-1", prompt: "next use /$emil-design-vocabulary" }]}
        chat="c"
        t={((key: string) => key) as never}
        commands={COMMANDS}
      />,
    ),
  );
  const word = box.querySelector<HTMLElement>(".cv-skill-word")!;
  expect(word.textContent).toBe("/emil-design-vocabulary");
  expect(word.dataset.tooltip).toBe(VOCABULARY);
  await act(async () => queue.unmount());
  box.remove();
});

test("never inside code: tilde fences, double-backtick spans with a backtick inside, inline and fenced code", async () => {
  // Literal prompt (a tilde fence is not Markdown the bubble renders): the shared code reading decides.
  let words = await bubble("~~~\nuse /review-pr\n~~~\nthen /review-pr");
  expect(words.map((word) => word.textContent)).toEqual(["/review-pr"]);
  expect(host.querySelector(".cv-user__bubble")!.textContent).toContain("use /review-pr");
  // Markdown prompt: a skill that also sits in code is left plain; another outside code is lit.
  words = await bubble("use `` a ` /review-pr `` now\n- and /$emil-design-vocabulary then");
  expect(words.map((word) => word.textContent)).toEqual(["/emil-design-vocabulary"]);
  // A tilde fence in a Markdown prompt: the renderer draws it as prose, the skill stays plain.
  words = await bubble("~~~\n/review-pr\n~~~\n- then /review-pr");
  expect(words.map((word) => word.textContent)).toEqual(["/review-pr"]);
  expect(host.querySelectorAll(".cv-skill-word").length).toBe(1);

  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const box = dom.window.document.createElement("div");
  dom.window.document.body.append(box);
  const queue = createRoot(box);
  await act(async () =>
    queue.render(
      <ComposerQueue
        queue={[
          { id: "q-1", prompt: "use `/review-pr` and\n```\n/review-pr\n```\nthen /review-pr" },
          { id: "q-2", prompt: "~~~\n/review-pr\n~~~ and `` a ` /review-pr ``" },
        ]}
        chat="c"
        t={((key: string) => key) as never}
        commands={COMMANDS}
      />,
    ),
  );
  const lit = (id: string) =>
    [...box.querySelectorAll(`[data-prompt-id="${id}"] .cv-skill-word`)].map((word) => word.textContent);
  expect(lit("q-1")).toEqual(["/review-pr"]);
  expect(lit("q-2")).toEqual([]);
  await act(async () => queue.unmount());
  box.remove();
});
