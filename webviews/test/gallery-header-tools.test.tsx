import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import entry from "../src/agent-session/acpmux/header/ChatHeaderTools.gallery";
import type { PlayContext, PlayTarget } from "../src/gallery/play";
import { UiProvider } from "../src/ui/UiProvider";
import { click, installDom, press, render, restoreDom, unmount } from "./viewer-empty-dom";

beforeAll(installDom);
afterEach(unmount);
afterAll(restoreDom);

test("header tools gallery uses the complete tab action model", () => {
  const props = entry.variants.idle!.props!;
  const rows = props.menu();
  const actions = rows.filter((row): row is Exclude<typeof row, "separator"> => row !== "separator");

  expect(actions.map((row) => row.key)).toEqual([
    "rename",
    "pin",
    "continue",
    "copy-link",
    "move-right",
    "new-workspace",
    "close",
  ]);
  expect(actions.at(-1)?.key).toBe("close");
  expect(props.tabTools).toBeUndefined();
  expect(entry.variants["quick-chat"]!.props!.tabTools).toBe(false);
});

test("header tools gallery scripts exercise keyboard navigation and focus return", async () => {
  const calls: string[] = [];
  const fakeDocument = {} as Document;
  const context = {
    click: async () => undefined,
    hover: async () => undefined,
    focus: async (target: PlayTarget) => {
      calls.push(`focus:${JSON.stringify(target)}`);
    },
    type: async () => undefined,
    press: async (key: string) => {
      calls.push(`press:${key}`);
    },
    pointer: { down: async () => undefined, move: async () => undefined, up: async () => undefined },
    waitFor: async () => undefined,
    find: () => fakeDocument.body!,
    document: fakeDocument,
  } satisfies PlayContext;

  await entry.variants["keyboard-menu"]!.play!(context);
  expect(calls).toEqual([
    'focus:{"role":"button","name":"Chat actions"}',
    "press:Enter",
    "press:ArrowDown",
    "press:Escape",
  ]);

  calls.length = 0;
  await entry.variants["keyboard-submenu"]!.play!(context);
  expect(calls).toEqual([
    'focus:{"role":"button","name":"Chat actions"}',
    "press:Enter",
    'focus:{"role":"menuitem","name":"Continue in"}',
    "press:ArrowRight",
    "press:Escape",
    "press:Escape",
  ]);
});

test("the gallery mounts the real menu and returns focus after Escape", async () => {
  const HeaderTools = await entry.load();
  const props = entry.variants.idle!.props!;
  const root = await render(
    <UiProvider container={document.body as HTMLElement}>
      <HeaderTools {...props} />
    </UiProvider>,
  );
  const trigger = root.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!;
  await click(trigger);
  const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
  expect(menu).not.toBeNull();
  const firstRow = menu.querySelector<HTMLElement>('[role="menuitem"]')!;
  await press(firstRow, "ArrowDown");
  expect(document.querySelector('[role="menuitem"][data-highlighted]')).not.toBeNull();
  await press(firstRow, "Escape");
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(document.activeElement).toBe(trigger);
});
