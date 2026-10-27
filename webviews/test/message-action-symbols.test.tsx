import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { setHarnessSymbolHost } from "../src/agent-session/shared/harnessIcons";
import { MessageActionIcon } from "../src/agent-session/acpmux/conversation/MessageActionRow";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root;
let host: HTMLElement;
beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
  root = createRoot(host);
});
afterAll(() => {
  act(() => root.unmount());
  setHarnessSymbolHost(undefined);
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("repeated message controls share the real host-rendered SF Symbol, with no command-derived symbol name", async () => {
  const names: string[] = [];
  const src = "data:image/png;base64,iVBORw0KGgo=";
  setHarnessSymbolHost(async (name) => {
    names.push(name);
    return src;
  });
  await act(async () =>
    root.render(
      <>
        <MessageActionIcon name="retry" />
        <MessageActionIcon name="retry" />
        <MessageActionIcon name="menu" />
        <MessageActionIcon name="copy" />
      </>,
    ),
  );
  expect(names).toEqual(["arrow.counterclockwise", "chevron.down", "doc.on.doc"]);
  expect(host.querySelectorAll('[data-symbol="arrow.counterclockwise"]')).toHaveLength(2);
  expect(host.querySelectorAll("svg")).toHaveLength(0);
  expect((host.firstElementChild as HTMLElement).style.maskImage).toContain(src);
});
