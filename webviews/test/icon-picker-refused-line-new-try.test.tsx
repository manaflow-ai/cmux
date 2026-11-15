// The line of a pick that the host refused ("The icon could not be applied. Try again.") is about
// that one try. When the person tries again, the line goes at the start of the new try, as the
// Image and SVG sheets' own error line does (icon-picker/AssetTab.tsx). The line is a band over the
// lower edge of the picker (styles.css `.icon-picker-error`): a band that stayed lay over the sheet's
// own error line, so a new try that the sheet refused (a bad URL, a wrong file type) showed no
// message at all.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const ASSET = `svg:sha256-${"a".repeat(64)}`;

/** Lets each promise of a pick (the download, the finish, its refusal) run to its end. */
const settle = () => act(async () => new Promise<void>((done) => setTimeout(done, 0)));

/**
 * Mounts the picker on its SVG sheet with a host that stores each URL's icon and answers each
 * finish as `answer` says, then makes one pick that the host refuses.
 */
async function mountWithRefusedPick() {
  const { mountIconPicker } = await import("../src/pages/icon-picker/mount");
  const { IconPickerOps } = await import("../src/pages/icon-picker/host");
  const finishes: Array<Record<string, unknown>> = [];
  let openSession!: (session: unknown) => void;
  let answer: () => Promise<unknown> = () => Promise.reject(new Error("refused"));
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      if (op === IconPickerOps.finish) {
        finishes.push(params);
        return answer();
      }
      if (op === IconPickerOps.assetFromURL) return Promise.resolve({ icon: ASSET });
      return Promise.resolve(null);
    },
    subscribe: async (_stream: string, onEvent: (data: unknown) => void) => {
      openSession = onEvent;
      return () => {};
    },
    handle: () => () => {},
  };
  host.replaceChildren();
  mountIconPicker(host, client as never);
  await act(async () => {});
  await act(async () => openSession({ id: "a", tab: "svg", assets: true }));
  const view = host.ownerDocument.defaultView!;
  const add = async (text: string) => {
    const url = host.querySelector<HTMLInputElement>('input[type="url"]')!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(view.HTMLInputElement.prototype, "value")!.set!.call(url, text);
      url.dispatchEvent(new view.Event("input", { bubbles: true }));
    });
    await act(async () => {
      host
        .querySelector("form.icon-asset-url")!
        .dispatchEvent(new view.Event("submit", { bubbles: true, cancelable: true }));
    });
    await settle();
  };
  await add("https://example.com/a.svg");
  return {
    add,
    finishes,
    refusedLine: () => host.querySelector(".icon-picker-error"),
    // The text and not the element: a red assert then prints one word, not the element's whole tree.
    refusedText: () => host.querySelector(".icon-picker-error")?.textContent ?? null,
    sheetLine: () => host.querySelector(".icon-asset-error"),
    answerWith: (next: () => Promise<unknown>) => {
      answer = next;
    },
  };
}

test("a pick that the host refuses shows the refused line", async () => {
  const { finishes, refusedLine, sheetLine } = await mountWithRefusedPick();
  expect(finishes).toEqual([{ session: "a", value: ASSET }]);
  expect(refusedLine()?.getAttribute("role")).toBe("alert");
  expect(refusedLine()?.textContent).not.toBe("");
  expect(sheetLine()?.textContent).toBe("");
});

test("a refused pick, then a sheet error: the sheet's line is seen", async () => {
  const { add, finishes, refusedText, sheetLine } = await mountWithRefusedPick();
  expect(refusedText()).not.toBeNull();
  // Not https: the sheet refuses it itself, and nothing goes to the host.
  await add("http://example.com/a.svg");
  expect(finishes.length).toBe(1);
  expect(sheetLine()?.textContent).not.toBe("");
  expect(refusedText()).toBeNull();
});

test("the refused line is away while the next pick waits for the host, and comes again when that pick is refused", async () => {
  const { add, finishes, refusedLine, refusedText, answerWith } = await mountWithRefusedPick();
  expect(refusedText()).not.toBeNull();
  let refuse!: (cause: Error) => void;
  answerWith(() => new Promise((_, no) => (refuse = no)));
  await add("https://example.com/b.svg");
  expect(finishes.length).toBe(2);
  expect(refusedText()).toBeNull();
  await act(async () => refuse(new Error("refused")));
  await settle();
  expect(refusedLine()?.getAttribute("role")).toBe("alert");
});
