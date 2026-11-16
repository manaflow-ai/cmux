// l10n-allow-file: test fixtures.
// The prompt coach card (PromptCoachCard.tsx): its label and correction count, the rewrite with its
// line breaks, Copy copying the rewrite, the × calling dismiss, and no × without one.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PromptCoachCard } from "./PromptCoachCard";
import { coachLines, COACH_MAX_LINES, promptCoachFromRecord } from "./promptCoach";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
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

const REWRITE = "Add a dark mode toggle in Settings > Appearance.\nFollow the system until set.";
const COACH = promptCoachFromRecord(
  { coachId: "c1", firstPrompt: "Add a dark mode toggle.", rewrite: `\n${REWRITE}\n\n`, corrections: 3 },
  "s1",
)!;

test("a coach record parses to its card's data; one without a rewrite or an id draws nothing", () => {
  expect(COACH).toEqual({
    coachId: "c1",
    sessionId: "s1",
    firstPrompt: "Add a dark mode toggle.",
    rewrite: REWRITE,
    corrections: 3,
  });
  expect(promptCoachFromRecord({ coachId: "c1", rewrite: "  " }, "s1")).toBeUndefined();
  expect(promptCoachFromRecord({ rewrite: "x" }, "s1")).toBeUndefined();
});

test("the rewrite block's estimate counts its lines and stops at the cap", () => {
  expect(coachLines("one line", 640)).toBe(1);
  expect(coachLines("a\nb\nc", 640)).toBe(3);
  expect(coachLines("x\n".repeat(40), 640)).toBe(COACH_MAX_LINES);
});

test("the card draws its label, the correction count and the rewrite with its line breaks", async () => {
  const container = await render(<PromptCoachCard coach={COACH} onDismiss={() => {}} />);
  expect(container.querySelector(".cv-coach__label")?.textContent).toBe(
    "Here's how this could have landed in one shot",
  );
  expect(container.querySelector(".cv-coach__meta")?.textContent).toBe("after 3 corrections");
  expect(container.querySelector(".cv-coach__prompt")?.textContent).toBe(REWRITE);
  // It never takes focus by itself: the composer keeps it.
  expect(container.ownerDocument.activeElement).toBe(container.ownerDocument.body);
});

test("Copy copies the rewrite, and × calls dismiss", async () => {
  const copied: string[] = [];
  let dismissed = 0;
  const container = await render(
    <PromptCoachCard
      coach={COACH}
      onDismiss={() => dismissed++}
      copy={async (text) => {
        copied.push(text);
        return true;
      }}
    />,
  );
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-coach__copy")!.click());
  expect(copied).toEqual([REWRITE]);
  expect(container.querySelector(".cv-coach__copy")?.hasAttribute("data-copied")).toBe(true);
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-coach__close")!.click());
  expect(dismissed).toBe(1);
});

test("a read-only card has Copy and no ×", async () => {
  const container = await render(<PromptCoachCard coach={COACH} />);
  expect(container.querySelector(".cv-coach__copy")).not.toBeNull();
  expect(container.querySelector(".cv-coach__close")).toBeNull();
});
