import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { configureCodexToolRuns, useCodexToolRuns } from "../src/agent-session/acpmux/codexToolRuns";

function Value() {
  return <span>{String(useCodexToolRuns())}</span>;
}

test("Codex-style tool grouping is on by default and follows the host theme", () => {
  configureCodexToolRuns(undefined);
  expect(renderToStaticMarkup(<Value />)).toContain("true");
  configureCodexToolRuns(false);
  expect(renderToStaticMarkup(<Value />)).toContain("false");
  configureCodexToolRuns(true);
  expect(renderToStaticMarkup(<Value />)).toContain("true");
  configureCodexToolRuns(false);
  configureCodexToolRuns(undefined);
  expect(renderToStaticMarkup(<Value />)).toContain("true");
});
