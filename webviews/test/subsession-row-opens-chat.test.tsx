// A sub-session's transcript row is its chat's button (subagents/AgentCard.tsx over the shared
// subagents/DisclosureRow.tsx), with no "Open chat" word beside it, and it reads as the rows it sits
// among: regular weight, the received-message line's 26px in 2px margins (Leo, 2026-10-29: "why is
// one of these bold? And why is there space, a fucking gap in between them? And why do you have the
// fucking open chat? Nobody asked for open chat. We can just click. Just have the thing be clickable,
// and then you can open it.").
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setPaneLanguage, translatorFor } from "../src/agent-session/acpmux/i18n";
import { AgentCard } from "../src/agent-session/acpmux/subagents/AgentCard";
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

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
  resetTranscriptDisclosure();
  setPaneLanguage("en");
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("a click on a sub-session's row opens its chat; its chevron alone opens the prompt", async () => {
  const opened: string[] = [];
  const container = await render(
    <AgentCard
      name="fleet-mesh"
      harness="codex"
      model="gpt-6.1-sol"
      state="working"
      disclosure
      disclosureKey="row"
      disclosureLabel="Started sub-session fleet-mesh"
      onOpen={() => void opened.push("fleet-mesh")}
    >
      <p className="prompt">Mesh the fleet.</p>
    </AgentCard>,
  );
  expect(container.textContent).not.toContain(t("subsession.openChat"));
  const line = container.querySelector<HTMLButtonElement>("button.cv-disclosure__open")!;
  const chevron = container.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!;
  // The line is the button: its label, model and state, and nothing after it but the chevron.
  expect(line.querySelector(".cv-disclosure__label")?.textContent).toBe("Started sub-session fleet-mesh");
  expect(line.textContent).toContain("gpt-6.1-sol");
  expect(line.title).toBe(t("subagents.open", { name: "fleet-mesh" }));
  expect(line.hasAttribute("aria-expanded")).toBe(false);
  expect(chevron.getAttribute("aria-expanded")).toBe("false");
  expect(chevron.getAttribute("aria-label")).toBe(t("message.details"));
  await act(async () => line.click());
  expect(opened).toEqual(["fleet-mesh"]);
  expect(container.querySelector(".prompt")).toBeNull();
  await act(async () => chevron.click());
  expect(chevron.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".prompt")?.textContent).toBe("Mesh the fleet.");
  expect(opened).toEqual(["fleet-mesh"]);
});

test("a row with no chat to open keeps its whole line as the disclosure", async () => {
  const container = await render(
    <AgentCard name="gone" disclosure disclosureKey="gone" disclosureLabel="Started sub-session gone">
      <p className="prompt">Gone.</p>
    </AgentCard>,
  );
  expect(container.querySelector(".cv-disclosure__open")).toBeNull();
  const toggle = container.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!;
  expect(toggle.querySelector(".cv-disclosure__label")?.textContent).toBe("Started sub-session gone");
  await act(async () => toggle.click());
  expect(container.querySelector(".prompt")?.textContent).toBe("Gone.");
});

test("a sub-session's card is its chat's button, with no Open chat word", async () => {
  const opened: string[] = [];
  const container = await render(
    <AgentCard name="fleet-mesh" model="gpt-6.1-sol" state="done" onOpen={() => void opened.push("fleet-mesh")} />,
  );
  expect(container.textContent).not.toContain(t("subsession.openChat"));
  const head = container.querySelector<HTMLButtonElement>("button.cv-agent-card__head")!;
  expect(head.textContent).toContain("fleet-mesh");
  await act(async () => head.click());
  expect(opened).toEqual(["fleet-mesh"]);
});

test("the row family is regular weight in the received line's 26px and 2px margins", () => {
  const css = readFileSync(new URL("../src/agent-session/acpmux/subagents/DisclosureRow.css", import.meta.url), "utf8");
  const rule = (selector: string) =>
    new RegExp(`(^|\\n)${selector.replace(/[.\\-]/g, (c) => `\\${c}`)} \\{([^}]*)\\}`).exec(css)?.[2] ?? "";
  expect(rule(".cv-disclosure")).toMatch(/margin:\s*2px 0;/);
  expect(rule(".cv-disclosure__line")).toMatch(/min-height:\s*var\(--cv-disclosure-line-height\);/);
  const conversation = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  expect(conversation).toMatch(/--cv-disclosure-line-height:\s*26px;/);
  expect(rule(".cv-disclosure__label")).toMatch(/font-weight:\s*400;/);
  expect(css).not.toMatch(/font-weight:\s*(500|600|bold)/);
});
