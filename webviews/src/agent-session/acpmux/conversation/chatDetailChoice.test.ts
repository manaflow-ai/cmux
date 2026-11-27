// Each chat's place on the detail ladder (chatDetail.ts), kept per chat with a default setting. The
// two old per-chat maps (Presentation and Transcript View) still read, so no one loses a choice;
// writes go to the new map and the new setting `agentPane.display.detail`.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { chatDisplayValues, resetChatDisplayForTests, setChatDisplay } from "../chatDisplay";
import {
  chatDetailOf,
  hasOwnChatDetail,
  makeChatDetailDefault,
  resetChatDetails,
  setChatDetail,
} from "./chatDetailChoice";

const scope = globalThis as Record<string, unknown>;
let dom: JSDOM;
let savedStorage: unknown;

beforeAll(() => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  savedStorage = scope.localStorage;
  scope.localStorage = dom.window.localStorage;
});

afterAll(() => {
  dom.window.close();
  if (savedStorage === undefined) delete scope.localStorage;
  else scope.localStorage = savedStorage;
});

afterEach(() => {
  resetChatDetails();
  localStorage.clear();
  resetChatDisplayForTests();
});

test("a chat's old Presentation and Transcript View choices read as its level", () => {
  localStorage.setItem("cmux.acpmux.presentation", JSON.stringify({ a: "messages", c: "transcript" }));
  localStorage.setItem("cmux.acpmux.transcriptView", JSON.stringify({ a: "verbose", b: "thinking" }));
  expect(chatDetailOf("a")).toBe("messages");
  expect(chatDetailOf("b")).toBe("thinking");
  expect(chatDetailOf("c")).toBe("normal");
  expect(hasOwnChatDetail("b")).toBe(true);
  expect(chatDetailOf("d")).toBe("normal");
  expect(hasOwnChatDetail("d")).toBe(false);
});

test("a pick writes the new map, and wins over the old ones", () => {
  localStorage.setItem("cmux.acpmux.presentation", JSON.stringify({ a: "messages" }));
  setChatDetail("a", "verbose");
  expect(chatDetailOf("a")).toBe("verbose");
  expect(JSON.parse(localStorage.getItem("cmux.acpmux.detail")!)).toEqual({ a: "verbose" });
});

test("Make default writes the new setting, and the chat follows it", () => {
  setChatDetail("a", "thinking");
  makeChatDetailDefault("a", "messages");
  expect(chatDisplayValues()["agentPane.display.detail"]).toBe("messages");
  expect(hasOwnChatDetail("a")).toBe(false);
  expect(chatDetailOf("a")).toBe("messages");
  expect(chatDetailOf("b")).toBe("messages");
});

test("a chat without a level follows the default, read from either old setting", () => {
  setChatDisplay({ "agentPane.display.presentation": "messages" });
  expect(chatDetailOf("a")).toBe("messages");
  setChatDisplay({ "agentPane.display.transcriptView": "thinking" });
  expect(chatDetailOf("a")).toBe("thinking");
  setChatDisplay({ "agentPane.display.detail": "verbose", "agentPane.display.presentation": "messages" });
  expect(chatDetailOf("a")).toBe("verbose");
});
