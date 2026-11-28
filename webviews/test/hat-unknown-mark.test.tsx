// The composer hat draws no generic sparkle for an agent whose harness is not known yet, and never
// names a run "acpmux" (Leo, 2026-11-27: "there was a really dumb looking symbol in the top left of
// the composer hat when i loaded into this chat"; it sat before an "acpmux ⌄" chip).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentIdentity } from "../src/agent-session/acpmux/subagents/AgentIdentity";
import { SUBAGENT_FALLBACK } from "../src/agent-session/acpmux/subagents/agentIdentityModel";

describe("hat marks with an unknown harness", () => {
  test("blankUnknown keeps the slot and draws no glyph", () => {
    const html = renderToStaticMarkup(
      <AgentIdentity tone={3} size={12} fallback={SUBAGENT_FALLBACK} plain blankUnknown />,
    );
    expect(html).toContain('data-agent-mark="unknown"');
    expect(html).toContain("width:12px");
    expect(html).not.toContain("<svg");
  });

  test("a known harness still draws its mark", () => {
    const html = renderToStaticMarkup(
      <AgentIdentity harness="claude" tone={3} size={12} fallback={SUBAGENT_FALLBACK} plain blankUnknown />,
    );
    expect(html).not.toContain('data-agent-mark="unknown"');
  });

  test("without blankUnknown the fallback glyph stays (every other surface)", () => {
    const html = renderToStaticMarkup(<AgentIdentity tone={3} size={12} fallback={SUBAGENT_FALLBACK} plain />);
    expect(html).not.toContain('data-agent-mark="unknown"');
  });

  test("a run is never named acpmux", () => {
    const fold = readFileSync(
      new URL("../src/agent-session/acpmux/subagents/subagentFold.ts", import.meta.url),
      "utf8",
    );
    expect(fold).not.toMatch(/\?\?\s*"acpmux"/u);
  });
});
