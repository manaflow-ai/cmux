// The Channels composer's right-click menu (POLISH.md right-click contract): Cut, Copy, Paste, Paste
// as Plain Text, Attach Files… and Insert Mention, never WebKit's own menu. The edits run in the app
// as the page view's own responder actions (`cmux.app.edit`), so the page never reads the pasteboard.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Composer } from "../src/pages/home-channels/Composer";
import { ComposerEdit, type ComposerEditCommand } from "../src/pages/home-channels/composerEdit";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(table, ["en"]);
const { t } = strings;

async function render(container: HTMLElement, edit?: (command: ComposerEditCommand) => void) {
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ComposerEdit.Provider value={edit}>
        <Composer
          strings={strings}
          placeholder="Message"
          label="Message"
          onSend={async () => true}
          attachments={{ service: {} as never, conversation: "c1" }}
          people={[{ id: "p1", kind: "human", name: "Ada", chief: false }]}
        />
      </ComposerEdit.Provider>,
    );
  });
}

async function rightClickField(container: HTMLElement) {
  const field = container.querySelector<HTMLElement>(".hc-composer-field")!;
  await act(async () =>
    field.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 })),
  );
}

const menuItems = () => [...document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')];

test("a right-click in the composer opens its own menu, and its edits run in the app", async () => {
  const container = installDom();
  const ran: ComposerEditCommand[] = [];
  await render(container, (command) => ran.push(command));
  await rightClickField(container);

  expect(menuItems().map((item) => item.textContent)).toEqual([
    t("composer.menu.cut"),
    t("composer.menu.copy"),
    t("composer.menu.paste"),
    t("composer.menu.pasteAsPlainText"),
    t("composer.menu.attachFiles"),
    t("composer.menu.insertMention"),
  ]);
  // Nothing is selected in the field: Cut and Copy are off, the pastes are on.
  const off = (label: string) =>
    (menuItems().find((item) => item.textContent === label) as HTMLButtonElement | undefined)?.disabled;
  expect(off(t("composer.menu.cut"))).toBe(true);
  expect(off(t("composer.menu.copy"))).toBe(true);
  expect(off(t("composer.menu.paste"))).toBe(false);

  await act(async () =>
    menuItems()
      .find((item) => item.textContent === t("composer.menu.paste"))!
      .click(),
  );
  expect(ran).toEqual(["paste"]);
  expect(document.querySelector('[role="menu"]')).toBeNull();
});

test("Attach Files… opens the file chooser, and a page with no host keeps the edits off", async () => {
  const container = installDom();
  await render(container);
  let chose = 0;
  container.querySelector<HTMLInputElement>('input[type="file"]')!.click = () => void chose++;
  await rightClickField(container);
  const paste = menuItems().find((item) => item.textContent === t("composer.menu.paste")) as HTMLButtonElement;
  expect(paste.disabled).toBe(true);
  await act(async () =>
    menuItems()
      .find((item) => item.textContent === t("composer.menu.attachFiles"))!
      .click(),
  );
  expect(chose).toBe(1);
});
