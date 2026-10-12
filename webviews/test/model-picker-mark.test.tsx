// Leo, 2026-10-12: the model chip of a folder profile ("Vercel AI Gateway/Apex") drew a broken
// square for its icon: the chip looked up the profile's own id, which names no brand, and an
// unknown mark drew a placeholder square. The chip draws the profile's mark (its icon or family,
// as the rail does), and a mark nobody knows draws nothing.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentMark } from "../src/agent-session/shared/AgentMark";
import { ModelPicker } from "../src/agent-session/acpmux/ModelPicker";

type Props = Parameters<typeof ModelPicker>[0];
const chip = (catalog: Props["catalog"], harness: string, label: string, switching?: Props["switching"]) =>
  renderToStaticMarkup(
    <ModelPicker
      catalog={catalog}
      harness={harness}
      switching={switching}
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

test("a profile whose icon names no brand falls back to its family's mark", () => {
  const html = chip([profile({ icon: "/icons/vercel.svg", family: "claude" })], "vercel-ai-gateway", "Apex");
  expect(html).toContain('data-agent="claude"');
});

test("while a switch to a profile starts, the chip draws that profile's mark", () => {
  const claude = { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] };
  const catalog = [claude, profile({ icon: "/icons/vercel.svg", family: "openai" })];
  const looked = chip(catalog, "claude", "Opus 5.5", { harness: "vercel-ai-gateway", name: "Apex" });
  expect(looked).toContain('data-agent="openai"');
  const given = chip(catalog, "claude", "Opus 5.5", { harness: "vercel-ai-gateway", name: "Apex", mark: "gemini" });
  expect(given).toContain('data-agent="gemini"');
});

test("a row's unknown mark keeps its slot, so names line up", () => {
  const html = renderToStaticMarkup(<AgentMark agent="vercel-ai-gateway" size={14} reserve />);
  expect(html).not.toContain("<svg");
  expect(html).toContain('class="agent-mark agent-mark-empty"');
  expect(html).toContain("width:14px");
  expect(html).toContain("height:14px");
});
