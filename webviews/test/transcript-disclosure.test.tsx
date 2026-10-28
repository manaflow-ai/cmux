import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import {
  resetTranscriptDisclosure,
  TranscriptDisclosureProvider,
  useTranscriptDisclosure,
} from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function Probe({ disclosureKey }: { disclosureKey: string }) {
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  return (
    <button type="button" aria-expanded={open} onClick={() => setOpen((current) => !current)}>
      {open ? "open" : "closed"}
    </button>
  );
}

function render(sessionId: string, disclosureKey: string) {
  act(() => {
    root ??= createRoot(container);
    root.render(
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <Probe disclosureKey={disclosureKey} />
      </TranscriptDisclosureProvider>,
    );
  });
}

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetTranscriptDisclosure();
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetTranscriptDisclosure();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("disclosure defaults closed, survives virtualization remounts, and persists by stable key", () => {
  render("session-a", "command:tool-1");
  const button = () => container.querySelector<HTMLButtonElement>("button")!;
  expect(button().getAttribute("aria-expanded")).toBe("false");
  act(() => button().click());
  expect(button().getAttribute("aria-expanded")).toBe("true");

  act(() => root!.unmount());
  root = undefined;
  render("session-a", "command:tool-1");
  expect(button().getAttribute("aria-expanded")).toBe("true");
  expect(JSON.parse(dom!.window.localStorage.getItem("cmux.acpmux.transcriptDisclosure")!)).toEqual({
    "session-a": { "command:tool-1": true },
  });
});

test("disclosure state is isolated between sessions", () => {
  render("session-a", "group:commands:tool-1");
  const button = () => container.querySelector<HTMLButtonElement>("button")!;
  act(() => button().click());
  render("session-b", "group:commands:tool-1");
  expect(button().getAttribute("aria-expanded")).toBe("false");
});
