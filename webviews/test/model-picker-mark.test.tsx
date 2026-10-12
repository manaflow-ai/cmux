// Leo, 2026-10-12: the model chip of a folder profile ("Vercel AI Gateway/Apex") drew a broken
// square for its icon: the chip looked up the profile's own id, which names no brand, and an
// unknown mark drew a placeholder square. The chip draws the profile's mark (its icon or family,
// as the rail does), and a mark nobody knows draws nothing.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentMark } from "../src/agent-session/shared/AgentMark";
import { ModelPicker } from "../src/agent-session/acpmux/ModelPicker";

const chip = (catalog: Parameters<typeof ModelPicker>[0]["catalog"], harness: string, label: string) =>
  renderToStaticMarkup(
    <ModelPicker
      catalog={catalog}
      harness={harness}
      model="apex"
      label={label}
      efforts={[]}
      recents={[]}
      onLand={() => undefined}
      onEffort={() => undefined}
    />,
  );

const profile = (extra: { icon?: string; family?: string }) => ({
  id: "vercel-ai-gateway",
  name: "Vercel AI Gateway",
  models: [{ id: "apex", name: "Apex" }],
  folder: { folder: "/Users/me/app", state: "enabled" as const },
  ...extra,
});

test("an unknown mark draws nothing, never a placeholder glyph", () => {
  for (const agent of ["vercel-ai-gateway", "/icons/vercel.svg", "", undefined])
    expect(renderToStaticMarkup(<AgentMark agent={agent} size={15} />)).toBe("");
  expect(renderToStaticMarkup(<AgentMark agent="claude" size={15} />)).toContain('data-agent="claude"');
});

test("a folder profile's chip with an unknown icon draws no mark", () => {
  const html = chip([profile({ icon: "/icons/vercel.svg" })], "vercel-ai-gateway", "Apex");
  expect(html).toContain("Apex");
  expect(html).not.toContain("agent-mark");
});

test("a folder profile's chip draws the mark of its family, as its rail tab does", () => {
  const html = chip([profile({ family: "claude" })], "vercel-ai-gateway", "Apex");
  expect(html).toContain('data-agent="claude"');
});
