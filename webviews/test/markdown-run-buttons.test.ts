// Run buttons in the Markdown viewer (runButtons.ts): a shell block gets Run in its language row,
// a click sends its command (session prompts stripped), a destructive command asks first, and a
// block of another language gets none. Run all's steps come from the same document, so they are
// exactly the blocks that show Run (fixture runbooks in test/fixtures/runbooks/).
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { MarkdownEditor as Editor } from "../src/pages/markdown/editor";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "Element",
    "getComputedStyle",
    "MutationObserver",
    "DOMParser",
    "Text",
    "requestAnimationFrame",
    "KeyboardEvent",
    "MouseEvent",
    "Event",
  ])
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  (dom.window.document as unknown as { elementFromPoint: () => null }).elementFromPoint = () => null;
  ({ MarkdownEditor } = await import("../src/pages/markdown/editor"));
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
  document.body.innerHTML = "";
});

const DOC =
  "# Deploy\n\n```bash\nnpm ci\n```\n\n```console\n$ make\nok\n```\n\n```sh\nrm -rf dist\n```\n\n```json\n{}\n```\n";

const fixture = (name: string) => readFileSync(join(import.meta.dir, "fixtures/runbooks", name), "utf8");

async function setup(doc = DOC) {
  const sent: string[] = [];
  const runnable: boolean[] = [];
  const root = document.createElement("div");
  document.body.append(root);
  const editor = new MarkdownEditor({
    root,
    host: {
      openLink: () => {},
      imageURL: (src) => src,
      label: (key) => key,
      run: {
        runBlock: async (command) => {
          sent.push(command);
          if (command === "make") throw new Error("refused");
        },
        label: (key) => key,
      },
    },
    onRunnable: (value) => runnable.push(value),
  });
  editors.push(editor);
  await editor.create();
  editor.load(doc);
  return { root, sent, runnable, editor };
}

const click = (element: Element | null | undefined) =>
  element!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));

describe("Run buttons", () => {
  test("shell blocks get Run; other languages none", async () => {
    const { root } = await setup();
    const blocks = [...root.querySelectorAll(".md-code")];
    expect(blocks.map((block) => !!block.querySelector(".md-run-button"))).toEqual([true, true, true, false]);
  });

  test("Run sends the block's command; a console block sends its prompt lines; only a taken one reads Sent", async () => {
    const { root, sent } = await setup();
    const blocks = root.querySelectorAll(".md-code");
    click(blocks[0]!.querySelector(".md-run-button"));
    click(blocks[1]!.querySelector(".md-run-button"));
    expect(sent).toEqual(["npm ci", "make"]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(blocks[0]!.querySelector(".md-run")!.getAttribute("data-state")).toBe("sent");
    // The host refused `make`: its block still offers Run.
    expect(blocks[1]!.querySelector(".md-run")!.hasAttribute("data-state")).toBe(false);
    expect(blocks[1]!.querySelector(".md-run-button")!.textContent).toBe("run");
  });

  test("a pointer that left before the host answered never sees a stuck Sent", async () => {
    const { root } = await setup();
    const block = root.querySelector(".md-code")!;
    click(block.querySelector(".md-run-button"));
    block.querySelector(".md-run")!.dispatchEvent(new dom.window.Event("pointerleave"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(block.querySelector(".md-run")!.hasAttribute("data-state")).toBe(false);
  });

  test("a destructive command asks first; Cancel sends nothing, Run sends it", async () => {
    const { root, sent } = await setup();
    const block = root.querySelectorAll(".md-code")[2]!;
    click(block.querySelector(".md-run-button"));
    expect(sent).toEqual([]);
    expect(block.querySelector(".md-run")!.getAttribute("data-state")).toBe("ask");
    expect(block.querySelector(".md-run-ask")!.textContent).toBe("runAsk");
    click([...block.querySelectorAll(".md-run-button")].at(-1));
    expect(sent).toEqual([]);
    expect(block.querySelector(".md-run")!.hasAttribute("data-state")).toBe(false);
    click(block.querySelector(".md-run-button"));
    click(block.querySelector(".md-run-confirm"));
    expect(sent).toEqual(["rm -rf dist"]);
  });
});

describe("Run all steps", () => {
  const commands = async (doc: string) => (await setup(doc)).editor.runbookSteps().map((step) => step.command);

  test("a deploy guide's shell blocks are its steps, in order, with sections, leads, lines and risks", async () => {
    const { editor, runnable } = await setup(fixture("deploy.md"));
    const steps = editor.runbookSteps();
    expect(steps.map((step) => step.command)).toEqual([
      "npm ci",
      "npm run build",
      "wrangler login",
      "wrangler deploy --env production",
      "rm -rf dist .wrangler",
    ]);
    expect(steps.map((step) => step.section)).toEqual(["Deploy the web app", "Build", "Log in", "Ship", "Clean up"]);
    expect(steps[1]!.lead).toBe("Build the bundle. It should print built in.");
    expect(steps.map((step) => step.line)).toEqual([5, 13, 19, 27, 33]);
    expect(steps.map((step) => step.risks)).toEqual([
      [],
      [],
      ["credentials"],
      ["destructive", "decision"],
      ["destructive"],
    ]);
    expect(runnable).toEqual([true]);
  });

  test("list items: console prompts with continuations run; nested md and text fences are not steps", async () => {
    const steps = (await setup(fixture("onboarding.md"))).editor.runbookSteps();
    expect(steps.map((step) => step.command)).toEqual([
      "git clone https://github.com/example/app.git\ncd app && \\\n  ls",
      "export GITHUB_TOKEN=<your-token>",
    ]);
    expect(steps.map((step) => [step.section, step.lead, step.risks])).toEqual([
      ["Onboarding", "Clone the repository:", []],
      ["Onboarding", "Set your token:", ["credentials"]],
    ]);
  });

  test("tilde fences and a longer closing fence close a block", async () => {
    expect(await commands("~~~bash\nmake\n~~~~\n\n````sh\nmake test\n```\nstill inside\n````\n")).toEqual([
      "make",
      "make test\n```\nstill inside",
    ]);
  });

  test("an indented code block and a fence inside an HTML comment are not steps", async () => {
    const doc =
      "Intro:\n\n    ```bash\n    rm -rf /\n    ```\n\n<!--\n```bash\nrm -rf old\n```\n-->\n\n" +
      "- Item\n\n  <!--\n  ```bash\n  rm -rf older\n  ```\n  -->\n\n```bash\nmake\n```\n";
    expect(await commands(doc)).toEqual(["make"]);
  });

  test("a fence on a list item's line and one in a blockquote are steps", async () => {
    const doc = "- ```bash\n  npm ci\n  ```\n\n> Then:\n>\n> ```sh\n> make\n> ```\n";
    const steps = (await setup(doc)).editor.runbookSteps();
    expect(steps.map((step) => [step.command, step.line, step.lead])).toEqual([
      ["npm ci", 1, ""],
      ["make", 7, "Then:"],
    ]);
  });

  test("a doc with no runnable block reports none", async () => {
    const { editor, runnable } = await setup("# Notes\n\n```json\n{}\n```\n\n```bash\n\n```\n");
    expect(editor.runbookSteps()).toEqual([]);
    expect(runnable).toEqual([false]);
  });

  // The editor's load of a long doc is what is slow in jsdom; the step read itself is one pass.
  test("a long doc's steps come in one pass", async () => {
    const { editor } = await setup("## Step\n\nRun it:\n\n```bash\necho ok\n```\n\n".repeat(1_000));
    const started = performance.now();
    const steps = editor.runbookSteps();
    expect(performance.now() - started).toBeLessThan(1_000);
    expect(steps).toHaveLength(1_000);
    expect(steps[999]!.line).toBe(999 * 8 + 5);
  }, 60_000);
});
