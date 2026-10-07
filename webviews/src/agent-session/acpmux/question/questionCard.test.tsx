import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { JSDOM, VirtualConsole } from "jsdom";

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
const { QuestionCard } = await import("./QuestionCard");
const { COMPOSER_READY_EVENT } = await import("../composerFocus");
type AgentQuestion = import("./model").AgentQuestion;
type QuestionReply = import("./model").QuestionReply;

const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const fixture = (name: string): AgentQuestion => JSON.parse(fs.readFileSync(`${FIXTURES}${name}.json`, "utf8"));

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

async function render(question: AgentQuestion) {
  const replies: QuestionReply[] = [];
  await act(async () =>
    root.render(createElement(QuestionCard, { question, onReply: (reply: QuestionReply) => replies.push(reply) })),
  );
  return replies;
}

const card = () => doc.querySelector<HTMLFieldSetElement>("fieldset.acpmux-question")!;
const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-question-row")];
const submitButton = () => doc.querySelector<HTMLButtonElement>(".acpmux-question-submit")!;
const skipButton = () => doc.querySelector<HTMLButtonElement>(".acpmux-question-skip")!;

async function press(key: string, init: Partial<KeyboardEventInit> = {}, target: Element = rows()[0]!) {
  if (target instanceof dom.window.HTMLElement) target.focus();
  await act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

async function click(element: Element) {
  await act(async () => {
    element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  });
}

test("a pending question shows its header, prompt, numbered options and details", async () => {
  await render(fixture("pending-single"));
  expect(doc.querySelector(".acpmux-question-chip")?.textContent).toBe("Auth method");
  expect(card().querySelector("legend")?.textContent).toContain("Which auth method should the API use?");
  expect(rows().map((row) => row.querySelector(".acpmux-keycap")?.textContent)).toEqual(["1", "2", "3", "4"]);
  expect(rows()[0]!.textContent).toContain("OAuth 2.0");
  expect(rows()[0]!.querySelector(".acpmux-question-detail")?.textContent).toContain("Delegated sign-in");
  // Single select is a radio group; the Other row is the last radio.
  expect(card().querySelector("[role=radiogroup]")).not.toBeNull();
  expect(rows().map((row) => row.getAttribute("role"))).toEqual(["radio", "radio", "radio", "radio"]);
  expect(rows().every((row) => row.getAttribute("aria-checked") === "false")).toBe(true);
});

test("arrival never takes focus from the composer", async () => {
  const composer = doc.createElement("textarea");
  doc.body.append(composer);
  composer.focus();
  await render(fixture("pending-single"));
  expect(doc.activeElement).toBe(composer);
  composer.remove();
});

test("clicking an option answers a single question in the harness's shape", async () => {
  const replies = await render(fixture("pending-single"));
  await click(rows()[2]!);
  expect(replies).toEqual([
    {
      session: "sess_claude_1",
      permissionId: "perm_toolu_single",
      optionId: "allow_once",
      answers: { "Which auth method should the API use?": "Passkeys" },
    },
  ]);
});

test("a number key inside the card answers once; key repeat and modifiers do nothing", async () => {
  const replies = await render(fixture("pending-single"));
  await press("2", { repeat: true });
  await press("2", { metaKey: true });
  await press("2");
  await press("3");
  expect(replies.map((reply) => reply.answers)).toEqual([{ "Which auth method should the API use?": "API keys" }]);
});

test("multi-select shows checkmarks and submits only from Submit or Enter", async () => {
  const replies = await render(fixture("pending-multi"));
  expect(card().querySelector("[role=group]")).not.toBeNull();
  expect(submitButton().disabled).toBe(true);
  await click(rows()[0]!);
  await click(rows()[3]!);
  expect(rows().map((row) => row.getAttribute("aria-checked"))).toEqual(["true", "false", "false", "true", "false"]);
  expect(rows()[0]!.getAttribute("role")).toBe("checkbox");
  expect(replies).toEqual([]);
  expect(submitButton().disabled).toBe(false);
  await click(submitButton());
  expect(replies[0]?.answers).toEqual({ "Which platforms should the first release support?": "macOS, Web" });
});

test("the Other row opens a text field whose text answers", async () => {
  const replies = await render(fixture("pending-other-typing"));
  await press("4");
  const field = doc.querySelector<HTMLInputElement>(".acpmux-question-other input")!;
  expect(field).not.toBeNull();
  expect(doc.activeElement).toBe(field);
  // A digit typed in the field is text, not a row key.
  await press("1", {}, field);
  expect(replies).toEqual([]);
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "Mutual TLS");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await press("Enter", {}, field);
  expect(replies[0]?.answers).toEqual({ "Which auth method should the API use?": "Mutual TLS" });
});

test("Skip declines with the reject option", async () => {
  const replies = await render(fixture("pending-single"));
  await click(skipButton());
  expect(replies).toEqual([{ session: "sess_claude_1", permissionId: "perm_toolu_single", optionId: "reject_once" }]);
});

test("Escape hands the keyboard back to the composer without answering", async () => {
  const replies = await render(fixture("pending-single"));
  let claimed = 0;
  const claim = () => (claimed += 1);
  dom.window.addEventListener(COMPOSER_READY_EVENT, claim);
  await press("Escape");
  dom.window.removeEventListener(COMPOSER_READY_EVENT, claim);
  expect(replies).toEqual([]);
  expect(claimed).toBe(1);
  expect(card().contains(doc.activeElement)).toBe(false);
});

test("a question with previews shows the highlighted option's preview in a labelled region", async () => {
  await render(fixture("pending-with-preview"));
  const region = () => doc.querySelector<HTMLElement>(".acpmux-question-preview")!;
  // A labelled section is a region landmark.
  expect(region().tagName).toBe("SECTION");
  expect(doc.getElementById(region().getAttribute("aria-labelledby")!)?.textContent).toContain("Sidebar");
  expect(region().querySelector("pre")?.textContent).toContain("│ General  │");
  await press("ArrowDown");
  expect(region().querySelector("pre")?.textContent).toContain("┌ General ┬ Keys");
});

test("several questions show one at a time with tabs, and advance as they are answered", async () => {
  const replies = await render(fixture("pending-4-questions"));
  const tabs = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-question-tab")];
  expect(tabs().length).toBe(4);
  expect(tabs()[0]!.getAttribute("aria-current")).toBe("step");
  await press("2");
  expect(tabs()[1]!.getAttribute("aria-current")).toBe("step");
  expect(doc.querySelector(".acpmux-question-chip")?.textContent).toBe("Platforms");
  await click(tabs()[3]!);
  expect(doc.querySelector(".acpmux-question-chip")?.textContent).toBe("Rollout");
  expect(replies).toEqual([]);
});

test("an answered question collapses to a summary that names who answered and where", async () => {
  const replies = await render(fixture("answered-remote-device"));
  const summary = doc.querySelector(".acpmux-question-answered")!;
  expect(summary.textContent).toContain("Auth method: OAuth 2.0");
  expect(summary.textContent).toContain("Lawrence");
  expect(summary.textContent).toContain("Lawrence's iPhone");
  expect(rows()).toEqual([]);
  await press("1", {}, summary);
  expect(replies).toEqual([]);
});

test("a cancelled question is one muted line", async () => {
  await render(fixture("cancelled"));
  expect(doc.querySelector(".acpmux-question-cancelled")?.textContent).toContain(
    "Which auth method should the API use?",
  );
  expect(rows()).toEqual([]);
});
