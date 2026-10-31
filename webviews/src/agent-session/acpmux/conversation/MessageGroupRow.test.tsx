// l10n-allow-file: test fixtures.
// A run of messages to other agents (MessageGroupRow.tsx): its line in each state, its card, that
// it opens and closes on the click, and that its clock runs only while a message goes out.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { translate } from "../i18n";
import { messageGroupLine } from "./MessageGroupRow";
import { configureMessageGroupLook } from "./messageGroupLook";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolRows } from "./TurnRows";
import { pageClocks } from "../../../ui/pageClock";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    // A visible page, so the group's clock runs (SubagentGroup.tsx `useNow` rests while hidden).
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "CustomEvent",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    CustomEvent: dom.window.CustomEvent,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  configureMessageGroupLook(undefined);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

let ids = 0;
const sendMessage = (to: string, message: string, status = "completed", startedAt = 1_000): AcpmuxActivity => {
  const id = `msg-${(ids += 1)}`;
  return {
    kind: "tool",
    text: "SendMessage",
    tool: {
      id,
      title: "SendMessage",
      kind: "other",
      status,
      startedAt,
      inputSummary: JSON.stringify({ to, message }),
      ...(status === "completed" && { endedAt: startedAt + 500 }),
    },
  };
};

const row = (items: AcpmuxActivity[]): AcpmuxRow => ({ id: "activity", version: 1, at: 1, kind: "activity", items });

const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

test("the line: present tense with the target in flight, past tense with a count once all went", () => {
  const whole = (line: ReturnType<typeof messageGroupLine>) => `${line.before}${line.target ?? ""}${line.after}`;
  expect(whole(messageGroupLine(t, ["Picker", "Rail"], [false, true]))).toBe("Messaging Rail");
  expect(messageGroupLine(t, ["Picker", "Rail"], [false, true]).target).toBe("Rail");
  expect(whole(messageGroupLine(t, ["Picker", "Picker", "Picker"], [false, false, false]))).toBe(
    "Messaged Picker 3 times",
  );
  expect(whole(messageGroupLine(t, ["Picker", "Rail", "Picker"], [false, false, false]))).toBe("Messaged 2 agents");
  expect(messageGroupLine(t, ["Picker", "Rail"], [false, false]).target).toBeUndefined();
});

test("a finished run of messages is one closed line; a click opens the card at once, a row per message", async () => {
  const items = [sendMessage("Picker", "one"), sendMessage("Picker", "two"), sendMessage("Picker", "three")];
  const node = await render(<ToolRows row={row(items)} />);
  const line = node.querySelector<HTMLButtonElement>(".cv-msggroup__line")!;
  expect(line.textContent).toContain("Messaged Picker 3 times");
  expect(line.getAttribute("aria-expanded")).toBe("false");
  expect(node.querySelector(".cv-msggroup__card")).toBeNull();
  expect(node.querySelector(".cv-msggroup__time")).toBeNull();
  await act(async () => line.click());
  // Open on the click: the card is in the DOM in the same commit, with no fold in between.
  expect(line.getAttribute("aria-expanded")).toBe("true");
  const entries = node.querySelectorAll(".cv-msggroup__card > .cv-msggroup__entry");
  expect(entries).toHaveLength(3);
  expect([...entries].every((entry) => entry.querySelector(".cv-message"))).toBe(true);
  await act(async () => line.click());
  expect(node.querySelector(".cv-msggroup__card")).toBeNull();
});

test("a run with a message going out starts open, names its target and ticks only while it goes", async () => {
  // The group's clock is the page's shared second clock (ui/pageClock.ts): it runs only while a
  // message goes out.
  const ticking = () => pageClocks().items.filter((clock) => clock.name === "elapsed" && clock.running).length;
  const started = Date.now() - 11_000;
  const done = sendMessage("Rail", "one", "completed", started);
  const going = sendMessage("Picker", "two", "in_progress", started + 4_000);
  const node = await render(<ToolRows row={row([done, going])} />);
  const line = node.querySelector(".cv-msggroup__line")!;
  expect(line.textContent).toContain("Messaging Picker");
  expect(node.querySelector(".cv-msggroup__time")?.textContent).toMatch(/^1[12]s$/);
  expect(line.getAttribute("aria-expanded")).toBe("true");
  expect(node.querySelectorAll(".cv-msggroup .cv-agentmsg__line")).toHaveLength(2);
  expect(ticking()).toBe(1);
  // The last message went: the clock stops and the group closes to its summary.
  const sent = { ...going, tool: { ...going.tool!, status: "completed", endedAt: started + 5_000 } };
  await act(async () => root!.render(<ToolRows row={row([done, sent])} />));
  expect(line.textContent).toContain("Messaged 2 agents");
  expect(node.querySelector(".cv-msggroup__time")).toBeNull();
  expect(line.getAttribute("aria-expanded")).toBe("false");
  expect(ticking()).toBe(0);
});

test("the before look draws each message as its own row", () => {
  configureMessageGroupLook("off");
  const html = renderToStaticMarkup(<ToolRows row={row([sendMessage("A", "one"), sendMessage("B", "two")])} />);
  expect(html).not.toContain("cv-msggroup");
  expect(html.match(/class="cv-agentmsg cv-message/g)).toHaveLength(2);
});
