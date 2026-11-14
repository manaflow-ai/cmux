// Every part a daemon message can carry draws in its row. A widget part reached the row and drew
// nothing: the row's part switch had no widget case (Codex review of #40999, F1). The switch's return
// type now leaves out `undefined`, so a part type with no case fails the typecheck; this test reads
// what each one draws.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Strings } from "../shared/i18n";
import type { HomeMessage, HomeParticipant, HomePart } from "./types";

const scope = globalThis as Record<string, unknown>;
const names = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "getComputedStyle"] as const;
const saved = names.map((name) => [name, scope[name]] as const);
const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
for (const name of names) scope[name] = (dom.window as unknown as Record<string, unknown>)[name];
scope.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) scope[name] = value;
  delete scope.IS_REACT_ACT_ENVIRONMENT;
});
const { createRoot } = await import("react-dom/client");
const { MessageRow } = await import("./MessageRow");

const strings = { t: (key: string) => key, format: (key: string) => key } as unknown as Strings;
const timeFormat = new Intl.DateTimeFormat("en", { hour: "numeric", minute: "2-digit", timeZone: "UTC" });

function drawn(part: HomePart): string {
  const message: HomeMessage = {
    id: "m1",
    conversation: "c1",
    seq: 1,
    author: "chief",
    createdAt: Date.UTC(2026, 10, 11, 4, 0),
    retracted: false,
    parts: [part],
    reactions: [],
  };
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  act(() =>
    root.render(
      <MessageRow
        message={message}
        head
        people={new Map<string, HomeParticipant>()}
        strings={strings}
        timeFormat={timeFormat}
        editing={false}
        onReact={() => {}}
      />,
    ),
  );
  const text = host.querySelector(".hc-msg-other")?.textContent ?? "";
  act(() => root.unmount());
  return text;
}

test("a widget draws its fallback text", () => {
  expect(
    drawn({ type: "widget", app: "cmux/weather", widget: "cmux.chat.widget/1", props: {}, fallback: "Sunny, 21°" }),
  ).toBe("Sunny, 21°");
});

test("a location draws its label", () => {
  expect(drawn({ type: "location", latitude: 37.33, longitude: -122.01, label: "Meet here" })).toBe("Meet here");
});
