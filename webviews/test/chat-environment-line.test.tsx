// The chat header's Environment line (header/EnvironmentLine.tsx; Leo, 2026-10-20): a started chat
// says where it runs, machine · folder · branch, without opening the Inspector. It sits in the
// header's status slot, or leads the tools in a tab-row header; a connection problem's label takes
// its place in either, and clicking it opens the Inspector at Environment.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const local = { cwd: "/Users/leo/Projects/cmux", branch: "feat/inspector" } as Summary;

async function render(node: (modules: Awaited<ReturnType<typeof load>>) => ReactNode) {
  const modules = await load();
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  act(() => root!.render(node(modules)));
  return modules;
}

async function load() {
  const { EnvironmentLine } = await import("../src/agent-session/acpmux/header/EnvironmentLine");
  const { ChatHeaderStatus, ChatHeaderInlineStatus } =
    await import("../src/agent-session/acpmux/header/ChatHeaderStatus");
  return { EnvironmentLine, ChatHeaderStatus, ChatHeaderInlineStatus };
}

const line = () => host.querySelector<HTMLElement>(".acpmux-env-line");

test("the status slot names the machine, the folder and the branch, and opens the Inspector there", async () => {
  let opened = 0;
  await render(({ ChatHeaderStatus, EnvironmentLine }) => (
    <ChatHeaderStatus status="">
      <EnvironmentLine summary={local} machineName="cosmic-gray" onOpen={() => opened++} />
    </ChatHeaderStatus>
  ));
  const shown = line()!;
  expect(shown.tagName).toBe("BUTTON");
  expect(shown.closest(".acpmux-header-status-slot")).not.toBeNull();
  expect(shown.querySelector(".acpmux-env-line__machine")?.textContent).toBe("cosmic-gray");
  expect(shown.querySelector(".acpmux-env-line__folder")?.textContent).toBe("cmux");
  expect(shown.querySelector(".acpmux-env-line__branch")?.textContent).toBe("feat/inspector");
  expect(shown.getAttribute("aria-label")).toBe("Environment: cosmic-gray · cmux · feat/inspector");
  // The folder's full path, which the line cuts to its name.
  expect(shown.getAttribute("title")).toBe("/Users/leo/Projects/cmux");
  expect(shown.dataset.machine).toBe("local");
  act(() => shown.click());
  expect(opened).toBe(1);
});

test("a connection problem takes the slot; the line comes back once it clears", async () => {
  await render(({ ChatHeaderStatus, EnvironmentLine }) => (
    <ChatHeaderStatus status="Disconnected" detail="acpmux stopped answering">
      <EnvironmentLine summary={local} machineName="cosmic-gray" />
    </ChatHeaderStatus>
  ));
  expect(line()).toBeNull();
  expect(host.querySelector(".acpmux-status")?.textContent).toBe("Disconnected");
  await render(({ ChatHeaderStatus, EnvironmentLine }) => (
    <ChatHeaderStatus status="">
      <EnvironmentLine summary={local} machineName="cosmic-gray" />
    </ChatHeaderStatus>
  ));
  expect(line()).not.toBeNull();
  expect(host.querySelector(".acpmux-status")).toBeNull();
});

test("a tab-row header leads its tools with the compact line, and the warning replaces it there too", async () => {
  await render(({ ChatHeaderInlineStatus, EnvironmentLine }) => (
    <ChatHeaderInlineStatus status="">
      <EnvironmentLine summary={local} machineName="cosmic-gray" compact />
    </ChatHeaderInlineStatus>
  ));
  expect(line()?.classList.contains("acpmux-env-line--compact")).toBe(true);
  expect(host.querySelector(".acpmux-header-status-slot")).toBeNull();
  await render(({ ChatHeaderInlineStatus, EnvironmentLine }) => (
    <ChatHeaderInlineStatus status="Disconnected">
      <EnvironmentLine summary={local} machineName="cosmic-gray" compact />
    </ChatHeaderInlineStatus>
  ));
  expect(line()).toBeNull();
  expect(host.querySelector(".acpmux-status--inline")?.textContent).toBe("Disconnected");
});

test("an SSH chat names its host; without the Inspector the line is a note, not a button", async () => {
  await render(({ EnvironmentLine }) => (
    <EnvironmentLine
      summary={{ ...local, peer: "huge-blue", host: "huge-blue" } as Summary}
      machineName="cosmic-gray"
      peerKinds={{ "huge-blue": "ssh" }}
    />
  ));
  const shown = line()!;
  expect(shown.tagName).toBe("DIV");
  expect(shown.getAttribute("role")).toBe("note");
  expect(shown.dataset.machine).toBe("ssh");
  expect(shown.querySelector(".acpmux-env-line__machine")?.textContent).toBe("huge-blue");
});

test("before the session says where it runs there is no line", async () => {
  await render(({ EnvironmentLine }) => <EnvironmentLine summary={undefined} machineName="cosmic-gray" />);
  expect(line()).toBeNull();
  await render(({ EnvironmentLine }) => (
    <EnvironmentLine summary={{} as Summary} machineName="cosmic-gray" onOpen={() => undefined} />
  ));
  expect(line()).toBeNull();
});

test("a local worktree chat leaves the branch to the worktree pill; a remote one keeps it", async () => {
  const worktree = { ...local, worktree: "/Users/leo/Projects/cmux-wt/inspector" } as Summary;
  await render(({ EnvironmentLine }) => <EnvironmentLine summary={worktree} machineName="cosmic-gray" />);
  expect(line()!.querySelector(".acpmux-env-line__branch")).toBeNull();
  expect(line()!.getAttribute("aria-label")).toBe("Environment: cosmic-gray · cmux");
  await render(({ EnvironmentLine }) => (
    <EnvironmentLine
      summary={{ ...worktree, peer: "huge-blue", host: "huge-blue" } as Summary}
      peerKinds={{ "huge-blue": "ssh" }}
    />
  ));
  expect(line()!.querySelector(".acpmux-env-line__branch")?.textContent).toBe("feat/inspector");
});

test("the root folder reads /", async () => {
  await render(({ EnvironmentLine }) => (
    <EnvironmentLine summary={{ cwd: "/", branch: "main" } as Summary} machineName="cosmic-gray" />
  ));
  expect(line()!.querySelector(".acpmux-env-line__folder")?.textContent).toBe("/");
});
