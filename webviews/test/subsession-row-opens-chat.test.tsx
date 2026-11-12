// A sub-session's transcript row names its chat with a link chip, the one part that opens it
// (subagents/AgentCard.tsx over the shared subagents/DisclosureRow.tsx; Leo, 2026-11-05: "subagents
// need to have their clickable bit be highlighted instead of the whole line click sending me to the
// subagent righ split"), with no "Open chat" word beside it, and it reads as the rows it sits
// among: regular weight, on the tool rows' line height, with no outer margin of its own (a gap
// belongs to its container, as the layout grid has it since #27580) (Leo, 2026-10-29: "why is
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
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosureModel";

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

test("a click on a sub-session's name chip opens its chat; the rest of its line opens the prompt", async () => {
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
  expect(container.querySelector("button.cv-disclosure__open")).toBeNull();
  const line = container.querySelector<HTMLElement>(".cv-disclosure__open")!;
  const chip = line.querySelector<HTMLButtonElement>("button.cv-agent-tag.is-open")!;
  const chevron = container.querySelector<HTMLButtonElement>("button.cv-disclosure__toggle")!;
  // The label is the chip; the model and state follow it, and nothing after them but the chevron.
  expect(chip.textContent).toBe("Started sub-session fleet-mesh");
  expect(line.textContent).toContain("gpt-6.1-sol");
  expect(chip.title).toBe(t("subagents.open", { name: "fleet-mesh" }));
  expect(chip.hasAttribute("aria-expanded")).toBe(false);
  expect(chevron.getAttribute("aria-expanded")).toBe("false");
  expect(chevron.getAttribute("aria-label")).toBe(t("message.details"));
  await act(async () => chip.click());
  expect(opened).toEqual(["fleet-mesh"]);
  expect(container.querySelector(".prompt")).toBeNull();
  // The line's model opens the panel, not the chat.
  await act(async () => line.querySelector<HTMLElement>(".cv-disclosure__meta")!.click());
  expect(chevron.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".prompt")?.textContent).toBe("Mesh the fleet.");
  expect(opened).toEqual(["fleet-mesh"]);
  await act(async () => chevron.click());
  expect(chevron.getAttribute("aria-expanded")).toBe("false");
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

test("a sub-session's card opens its chat from its name chip alone, with no Open chat word", async () => {
  const opened: string[] = [];
  const container = await render(
    <AgentCard name="fleet-mesh" model="gpt-6.1-sol" state="done" onOpen={() => void opened.push("fleet-mesh")} />,
  );
  expect(container.textContent).not.toContain(t("subsession.openChat"));
  expect(container.querySelector("button.cv-agent-card__head")).toBeNull();
  const head = container.querySelector<HTMLElement>(".cv-agent-card__head")!;
  await act(async () => head.click());
  expect(opened).toEqual([]);
  const chip = head.querySelector<HTMLButtonElement>("button.cv-agent-tag.is-open")!;
  expect(chip.textContent).toBe("fleet-mesh");
  await act(async () => chip.click());
  expect(opened).toEqual(["fleet-mesh"]);
});

test("the row family is regular weight on the tool rows' line, with no outer margin of its own", () => {
  const css = readFileSync(new URL("../src/agent-session/acpmux/subagents/DisclosureRow.css", import.meta.url), "utf8");
  const rule = (selector: string) =>
    new RegExp(`(^|\\n)${selector.replace(/[.\\-]/g, (c) => `\\${c}`)} \\{([^}]*)\\}`).exec(css)?.[2] ?? "";
  // A child never adds outer margin; the transcript row's frame and its container's gap give the room.
  expect(rule(".cv-disclosure")).toMatch(/margin:\s*0;/);
  expect(rule(".cv-disclosure__line")).toMatch(/min-height:\s*var\(--cv-disclosure-line-height\);/);
  const conversation = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  // The line is a tool row's height, whatever the density sets it to (#31497).
  expect(conversation).toMatch(/--cv-disclosure-line-height:\s*var\(--cv-tool-row-height\);/);
  expect(rule(".cv-disclosure__label")).toMatch(/font-weight:\s*400;/);
  expect(css).not.toMatch(/font-weight:\s*(500|600|bold)/);
});
