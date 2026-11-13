// The time a message after the first of its run shows in its gutter only while the row is hovered or
// focused (styles.css .hc-msg-hover-time; ledger.css places it over the row's top right). Hidden by
// opacity alone, it still sat over the message and took its clicks and text selection (CMUX-325), and
// screen readers read it again after the row's own label, which already says the time (CMUX-326).
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Strings } from "../shared/i18n";
import type { HomeMessage, HomeParticipant } from "./types";

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

const css = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
const rule = (selector: string) => css.match(new RegExp(`(?:^|\\n)${selector} \\{([^}]*)\\}`))?.[1] ?? "";

const strings = { t: (key: string) => key, format: (key: string) => key } as unknown as Strings;
const message: HomeMessage = {
  id: "m2",
  conversation: "c1",
  seq: 2,
  author: "ada",
  createdAt: Date.UTC(2026, 10, 9, 10, 42),
  retracted: false,
  parts: [{ type: "text", text: "and one more thing", mentions: [] }],
  reactions: [],
};
const people = new Map<string, HomeParticipant>();
const timeFormat = new Intl.DateTimeFormat("en", { hour: "numeric", minute: "2-digit", timeZone: "UTC" });

function row(head: boolean): string {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  act(() =>
    root.render(
      <MessageRow
        message={message}
        head={head}
        people={people}
        strings={strings}
        timeFormat={timeFormat}
        editing={false}
        onReact={() => {}}
      />,
    ),
  );
  const html = host.innerHTML;
  act(() => root.unmount());
  return html;
}

test("the row's label says the time; its gutter copy is hidden from screen readers", () => {
  const html = row(false);
  expect(html).toContain('aria-label="ada, 10:42 AM"');
  expect(html).toMatch(/<time class="hc-msg-hover-time" aria-hidden="true">10:42 AM<\/time>/);
});

test("the hidden time takes no clicks or selection, and still shows on hover and focus", () => {
  expect(rule("\\.hc-msg-hover-time")).toContain("opacity: 0;");
  expect(rule("\\.hc-msg-hover-time")).toContain("pointer-events: none;");
  expect(rule("\\.hc-msg-hover-time")).toContain("user-select: none;");
  const shown = css.match(
    /\.hc-msg:hover \.hc-msg-hover-time,\n\.hc-msg:focus-within \.hc-msg-hover-time \{([^}]*)\}/,
  )?.[1];
  expect(shown).toContain("opacity: 1;");
});
