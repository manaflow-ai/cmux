// The forum's current rules above the composer (hq#2570): nothing without rules; one line with
// the newest rule and how many there are; Show All lists each with who posted it (a person or an
// agent session) and its acks. Malformed rows of `_acpmux/forum/rules` are left out.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { Notice, NoticeSlot } from "./NoticeSlot";
import { forumRules, RulesNotice } from "./RulesNotice";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
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
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const reply = {
  rules: [
    {
      id: "a",
      key: "builds",
      body: "Builds run on the fleet.",
      author: { kind: "person", account: "leo" },
      created: 1,
      acks: [{ sessionId: "s1", at: 2 }],
    },
    {
      id: "b",
      key: "ci",
      body: "Wait with glaeda-gh.",
      author: { kind: "agent", sessionId: "s2", name: "ops" },
      created: 5,
      acks: [],
    },
    { id: "c", key: "bad", author: { kind: "person", account: "x" } },
    null,
    "row",
  ],
};

test("no rules, no card", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<RulesNotice rules={[]} />);
  });
  expect(container.innerHTML).toBe("");
});

test("one line with the newest rule, then every rule with its author and acks", async () => {
  const container = installDom();
  const rules = forumRules(reply);
  expect(rules.map((rule) => rule.id)).toEqual(["a", "b"]);
  await act(async () => {
    root = createRoot(container);
    root.render(<RulesNotice rules={rules} />);
  });
  expect(container.querySelector(".acpmux-rules-count")?.textContent).toBe("2");
  expect(container.querySelector(".acpmux-rules-newest")?.textContent).toContain("Wait with glaeda-gh.");
  expect(container.textContent).not.toContain("Builds run on the fleet.");
  const button = container.querySelector<HTMLButtonElement>('[data-notice-action="rules"]')!;
  await act(async () => button.click());
  const rows = [...container.querySelectorAll("[data-rule-key]")].map((row) => row.textContent ?? "");
  expect(rows).toHaveLength(2);
  expect(rows[0]).toContain("Builds run on the fleet.");
  expect(rows[0]).toContain("leo");
  expect(rows[0]).toContain("Acks: 1");
  expect(rows[1]).toContain("Acks: 0");
  expect(rows[1]).toContain("ops");
  expect(button.getAttribute("aria-expanded")).toBe("true");
});

test("the open list scrolls inside a bounded height, so long rules never push the composer out", () => {
  const css = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
  const rule = css.match(/\.acpmux-rules-list\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toMatch(/max-height:/);
  expect(rule).toMatch(/overflow-y:auto/);
});

test("the rules card waits while an update the person started shows, then comes back", async () => {
  const container = installDom();
  const rules = forumRules(reply);
  const draw = (updating: boolean) => (
    <NoticeSlot>
      <RulesNotice rules={rules} />
      <Notice id="harness-health" tier="update" when={updating}>
        <p className="updating">Updating</p>
      </Notice>
    </NoticeSlot>
  );
  await act(async () => {
    root = createRoot(container);
    root.render(draw(true));
  });
  expect(container.querySelector(".updating")).not.toBeNull();
  expect(container.querySelector(".acpmux-rules-notice")).toBeNull();
  await act(async () => root!.render(draw(false)));
  expect(container.querySelector(".updating")).toBeNull();
  expect(container.querySelector(".acpmux-rules-notice")).not.toBeNull();
});
