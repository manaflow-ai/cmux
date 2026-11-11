// l10n-allow-file: test fixture questions, not shipped UI.
// A started chat's question in the composer hat (question/HatQuestions.tsx) is answered there, not
// only opened. Leo, 2026-11-10: "this is unusable to respond to i necessarily have to open... this is
// bad ui".
// - The first line says who asks and what about, never the chat's long title.
// - The whole question shows on More.
// - Its choices are buttons, the recommended one marked; a click sends that choice.
// - A typed answer goes with Send, and a refused one keeps the text and says so.
// - Open Chat stays.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { HatQuestion } from "../src/agent-session/acpmux/question/hatModel";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
class StillResizeObserver {
  observe() {}
  disconnect() {}
}
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  ResizeObserver: StillResizeObserver,
  requestAnimationFrame: (run: () => void) => setTimeout(run, 0) as unknown as number,
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});
(dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver = StillResizeObserver;
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent|InputEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { HatQuestions } = await import("../src/agent-session/acpmux/question/HatQuestions");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { CHILD_QUESTION } = await import("../src/gallery/fixtures/HatQuestionsStage");

async function mount(question: HatQuestion = CHILD_QUESTION, refuse = false) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const answered: string[] = [];
  const replied: string[] = [];
  const opened: string[] = [];
  await act(async () =>
    root.render(
      <HatQuestions
        questions={[question]}
        look="band"
        actions={{
          answer: async (_, answer) => {
            answered.push(answer.id);
            if (refuse) throw new Error("refused");
          },
          reply: async (_, text) => {
            replied.push(text);
            if (refuse) throw new Error("refused");
          },
          type: () => undefined,
          showCard: () => undefined,
          open: (shown) => void opened.push(shown.sessionId ?? ""),
        }}
      />,
    ),
  );
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const click = (element: Element | null) =>
    act(async () => {
      (element as HTMLElement).click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const type = (text: string) =>
    act(async () => {
      const field = $<HTMLInputElement>(".acpmux-hat-questions__field")!;
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(field, text);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  return { host, $, click, type, answered, replied, opened, unmount: () => act(async () => root.unmount()) };
}

test("the first line names who asks and what about; the choices are buttons, the recommended one marked", async () => {
  const hat = await mount();
  expect(hat.$(".acpmux-hat-questions__who")?.textContent).toBe("coord-deputy");
  expect(hat.$(".acpmux-hat-questions__about")?.textContent).toBe("Cleanup");
  // The question is on its own line under them, not cut beside the chat's title.
  expect(hat.$(".acpmux-hat-questions__head .acpmux-hat-questions__prompt")).toBeNull();
  expect(hat.$(".acpmux-hat-questions__question > .acpmux-hat-questions__words")).not.toBeNull();
  const answers = [...hat.host.querySelectorAll(".acpmux-hat-questions__answer")];
  expect(answers.map((button) => button.textContent)).toEqual([
    `Remove both${translate("hat.questions.recommended")}`,
    "Leave them",
  ]);
  expect(answers[0]!.hasAttribute("data-recommended")).toBe(true);
  await hat.click(answers[0]!);
  // The choice sends the option as the agent wrote it.
  expect(hat.answered).toEqual(["Remove both (Recommended)"]);
  await hat.unmount();
});

test("a typed answer goes with Send; an empty one can't", async () => {
  const hat = await mount();
  const send = () => hat.$<HTMLButtonElement>(".acpmux-hat-questions__send")!;
  expect(send().disabled).toBe(true);
  await hat.type("  Remove the older one only  ");
  expect(send().disabled).toBe(false);
  await hat.click(send());
  expect(hat.replied).toEqual(["Remove the older one only"]);
  await hat.unmount();
});

test("a refused answer says so and keeps the typed text for another try", async () => {
  const hat = await mount(CHILD_QUESTION, true);
  await hat.type("Leave them for now");
  await hat.click(hat.$(".acpmux-hat-questions__send"));
  expect(hat.$('[role="alert"]')?.textContent).toBe(translate("question.replyFailed"));
  expect(hat.$<HTMLInputElement>(".acpmux-hat-questions__field")!.value).toBe("Leave them for now");
  expect(hat.$<HTMLButtonElement>(".acpmux-hat-questions__send")!.disabled).toBe(false);
  await hat.unmount();
});

test("Open Chat stays, and a question needing its card offers no field", async () => {
  const hat = await mount({ ...CHILD_QUESTION, answers: [], typed: false });
  expect(hat.$(".acpmux-hat-questions__field")).toBeNull();
  const open = [...hat.host.querySelectorAll(".acpmux-hat-questions__quiet")].find(
    (button) => button.textContent === translate("hat.questions.open"),
  );
  await hat.click(open!);
  expect(hat.opened).toEqual(["coord-deputy"]);
  await hat.unmount();
});
