import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { closeWorkspace, seedStack, workspaceLead } from "./workspaces";

const css = readFileSync(new URL("./prototype.css", import.meta.url), "utf8");

function rule(selector: string): string {
  const start = css.indexOf(`${selector} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  const end = css.indexOf("}", start);
  expect(end).toBeGreaterThan(start);
  return css.slice(start, end);
}

test("tab close reserves a trailing title region without moving on reveal", () => {
  expect(rule(".proto-tab")).toMatch(/position:\s*relative/);
  expect(rule(".proto-tab-select")).toMatch(/padding-inline-start:\s*10px/);
  expect(rule(".proto-tab-select")).toMatch(/padding-inline-end:\s*6px/);
  expect(css).toMatch(/\.proto-tab\.has-close \.proto-tab-select\s*\{/);
  expect(css).toMatch(/padding-inline-end:\s*30px/);
  const close = rule(".proto-tab-close");
  expect(close).toMatch(/position:\s*absolute/);
  expect(close).toMatch(/inset-inline-end:\s*3px/);
  expect(close).toMatch(/top:\s*2px/);
});

test("tab close keeps pointer hover and keyboard focus reveal behavior", () => {
  expect(css).toMatch(/\.proto-tab:hover \.proto-tab-close,/);
  expect(css).toMatch(/\.proto-tab:focus-within \.proto-tab-close,/);
  expect(css).toMatch(/\.proto-tab-close:focus-visible\s*\{/);
  const close = rule(".proto-tab-close");
  expect(close).toMatch(/opacity:\s*0/);
  expect(close).toMatch(/pointer-events:\s*none/);
  const revealed = css.slice(css.indexOf(".proto-tab:hover .proto-tab-close,"), css.indexOf(".proto-tab-close:hover,"));
  expect(revealed).toMatch(/opacity:\s*1/);
  expect(revealed).toMatch(/pointer-events:\s*auto/);
});

test("workspace close removes all tabs and focuses the next workspace", () => {
  const workspace = seedStack.workspaces[0]!;
  const result = closeWorkspace(seedStack, workspace.id);
  expect(result.closed).toBe(true);
  expect(result.stack.workspaces.some((candidate) => candidate.id === workspace.id)).toBe(false);
  expect(result.stack.activeId).toBe(seedStack.workspaces[1]!.id);
  expect(result.focus).toEqual({
    workspaceId: seedStack.workspaces[1]!.id,
    tabId: seedStack.workspaces[1]!.activeTabId,
  });
  expect(workspaceLead(workspace).kind).toBe("agent");
});
