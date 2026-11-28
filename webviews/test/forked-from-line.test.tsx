// A fork's "Forked from <chat>" line names the chat it came from with the session link chip a
// sender's name is, which opens that chat (#50086; Leo, 2026-11-22: "i also do wonder about the
// state of affairs of our forking behaviour and if it's as good as it can be"). Before, the line was
// plain muted text and nothing in the fork's tab led back to its parent.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { ForkedFromLine, forkedFromParts } from "../src/agent-session/acpmux/conversation/ForkedFromLine";
import { NoticeRow } from "../src/agent-session/acpmux/rows/NoticeRow";
import { SubsessionContext, SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";

const t = translatorFor("en");
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    NodeFilter: dom.window.NodeFilter,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(node));
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

const CHAT = "Remember Codeword PELICAN-41";
const TEXT = t("notice.forkedFrom", { chat: CHAT });
const noop = () => {};

test("the chat's name in the line is cut out at its last mention", () => {
  expect(forkedFromParts(TEXT, CHAT)).toEqual([
    TEXT.slice(0, TEXT.indexOf(CHAT)),
    TEXT.slice(TEXT.indexOf(CHAT) + CHAT.length),
  ]);
  // A subagent's line ("Forked from <subagent> of <chat>") whose subagent name holds the chat's.
  expect(forkedFromParts("Forked from Plan of Plan.", "Plan")).toEqual(["Forked from Plan of ", "."]);
  expect(forkedFromParts("Forked from another chat.", CHAT)).toBeUndefined();
  expect(forkedFromParts(TEXT, "")).toBeUndefined();
});

test("a click on the chat's name in a fork's line opens the chat it was forked from, as a sender", async () => {
  const opened: string[] = [];
  const row = {
    id: "forked-from-9",
    version: 1,
    at: 0,
    kind: "notice",
    text: TEXT,
    forkedFrom: { parentId: "parent-id", chat: CHAT },
  };
  const container = await render(
    <SubsessionContext.Provider
      value={{ store: new SubsessionStore(), open: noop, openSender: (id) => void opened.push(id) }}
    >
      <NoticeRow row={row} onToggleActivity={noop} expanded={false} />
    </SubsessionContext.Provider>,
  );
  const line = container.querySelector(".cv-forked-from")!;
  expect(line.textContent).toBe(TEXT);
  const chip = line.querySelector<HTMLButtonElement>("button.cv-agent-tag.is-open")!;
  expect(chip.textContent).toBe(CHAT);
  expect(chip.getAttribute("aria-label")).toBe(t("subagents.open", { name: CHAT }));
  expect(chip.getAttribute("data-open-session")).toBe("parent-id");
  await act(async () => chip.click());
  expect(opened).toEqual(["parent-id"]);
});

test("without a way to open chats, or once the parent is gone, the line stays plain text", async () => {
  const plain = await render(<ForkedFromLine text={TEXT} forkedFrom={{ parentId: "parent-id", chat: CHAT }} />);
  expect(plain.querySelector("button")).toBeNull();
  expect(plain.textContent).toBe(TEXT);
  if (root) await act(async () => root!.unmount());
  const gone = await render(
    <SubsessionContext.Provider value={{ store: new SubsessionStore(), open: noop }}>
      <NoticeRow
        row={{ id: "f", version: 1, at: 0, kind: "notice", text: t("notice.forkedFromGone") }}
        onToggleActivity={noop}
        expanded={false}
      />
    </SubsessionContext.Provider>,
  );
  expect(gone.querySelector("button")).toBeNull();
});
