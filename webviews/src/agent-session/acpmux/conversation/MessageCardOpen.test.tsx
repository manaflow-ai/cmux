// l10n-allow-file: test fixtures.
// A sent message's recipient chip goes to the recipient (Leo, 2026-10-31, on "Sent to <Unstick DEV
// tip publish>": "i NEED TO BE ABEL TO CLICK THAT LABEL TO GO TO THE CHAT"). A SendMessage names a
// subagent by its agentId: the chip opens that subagent's view, and the click is the chip's own (the
// line does not open the message too). With nothing to open, the chip stays plain.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../model";
import { agentMessage } from "./agentMessages";
import { AgentNamesContext, AgentOpenContext, agentViews } from "./agentNames";
import { MessageCard } from "./MessageCard";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import type { Subagent } from "../subagents/subagentFold";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function render(node: ReactNode): Promise<HTMLElement> {
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
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const tool: NonNullable<AcpmuxActivity["tool"]> = {
  id: "toolu_send",
  title: "SendMessage",
  kind: "other",
  status: "completed",
  inputSummary: JSON.stringify({ to: "a39e817af38ddf5e7", message: "Re-run the publish from the tip." }),
  output: JSON.stringify({ queued: true }),
};
const agents = [
  { id: "toolu_agent", agentId: "a39e817af38ddf5e7", task: "Unstick DEV tip publish" },
] as unknown as Subagent[];

const card = () => <MessageCard item={{ kind: "tool", text: tool.title, tool }} message={agentMessage(tool)!} />;

test("a SendMessage's recipient chip opens the subagent it names, and only that", async () => {
  const opened: string[] = [];
  const container = await render(
    <AgentNamesContext.Provider value={new Map([["a39e817af38ddf5e7", "Unstick DEV tip publish"]])}>
      <AgentOpenContext.Provider value={{ views: agentViews(agents), open: (id) => opened.push(id) }}>
        {card()}
      </AgentOpenContext.Provider>
    </AgentNamesContext.Provider>,
  );
  const chip = container.querySelector<HTMLButtonElement>("button.cv-agentmsg__name");
  expect(chip?.textContent).toBe("Unstick DEV tip publish");
  await act(async () => chip!.click());
  expect(opened).toEqual(["toolu_agent"]);
  // The chip's click opens the subagent, not the message under the line.
  expect(container.querySelector(".cv-agentmsg")?.getAttribute("data-open")).toBeNull();
});

test("a recipient nothing opens stays a plain chip", async () => {
  const container = await render(card());
  expect(container.querySelector("button.cv-agentmsg__name")).toBeNull();
  expect(container.querySelector(".cv-agentmsg__name")?.textContent).toBe("a39e817a");
});
