// The chat's Messages/Transcript presentation (conversation/presentation.ts): each session may
// keep its own choice, while sessions without an override follow the global display setting.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  PRESENTATION_KEY,
  chatDisplayValues,
  defaultPresentation,
  setChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import {
  hasOwnPresentation,
  makePresentationDefault,
  presentationOf,
  resetPresentations,
  setPresentation,
} from "../src/agent-session/acpmux/conversation/presentation";

let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "localStorage"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, localStorage: dom.window.localStorage });
  resetPresentations();
  setChatDisplay({});
});

afterEach(() => {
  resetPresentations();
  setChatDisplay({});
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a session defaults to Transcript and stores its own Messages choice", () => {
  expect(defaultPresentation()).toBe("transcript");
  expect(presentationOf("chat-a")).toBe("transcript");
  expect(hasOwnPresentation("chat-a")).toBe(false);

  setPresentation("chat-a", "messages");
  expect(presentationOf("chat-a")).toBe("messages");
  expect(presentationOf("chat-b")).toBe("transcript");
  expect(hasOwnPresentation("chat-a")).toBe(true);
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.presentation")!)).toEqual({
    "chat-a": "messages",
  });
});

test("sessions without an override follow the global presentation setting", () => {
  setChatDisplay({ [PRESENTATION_KEY]: "messages" });
  expect(defaultPresentation()).toBe("messages");
  expect(presentationOf("chat-a")).toBe("messages");

  setPresentation("chat-a", "transcript");
  expect(presentationOf("chat-a")).toBe("transcript");
  expect(presentationOf("chat-b")).toBe("messages");
  expect(chatDisplayValues()[PRESENTATION_KEY]).toBe("messages");
});

test("Make … the default clears this session override and writes the setting", () => {
  setPresentation("chat-a", "messages");
  makePresentationDefault("chat-a", "messages");
  expect(hasOwnPresentation("chat-a")).toBe(false);
  expect(presentationOf("chat-a")).toBe("messages");
  expect(chatDisplayValues()[PRESENTATION_KEY]).toBe("messages");
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.presentation") ?? "{}")).toEqual({});

  makePresentationDefault("chat-a", "transcript");
  expect(PRESENTATION_KEY in chatDisplayValues()).toBe(false);
  expect(presentationOf("chat-a")).toBe("transcript");
});

test("a storage event refreshes choices made by another pane", () => {
  setPresentation("chat-a", "messages");
  dom!.window.localStorage.setItem(
    "cmux.acpmux.presentation",
    JSON.stringify({ "chat-a": "transcript", "chat-b": "messages" }),
  );
  const event = Object.assign(new Event("storage"), { key: "cmux.acpmux.presentation" });
  globalThis.dispatchEvent(event);
  expect(presentationOf("chat-a")).toBe("transcript");
  expect(presentationOf("chat-b")).toBe("messages");
});
