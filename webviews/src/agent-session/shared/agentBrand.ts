import { AGENT_BRAND_LOOKUP, AGENT_BRANDS, type AgentBrandId, type AgentBrandSpec } from "./agentBrands.generated";

export { AGENT_BRANDS, AGENT_BRAND_RESOLUTION_CASES, SUPPORTED_AGENTS } from "./agentBrands.generated";
export type { AgentBrandId, AgentBrandSpec, BrandGradient, BrandPath, BrandTone } from "./agentBrands.generated";

/// The ids an agent string may be known by, most specific first. Must match
/// AgentBrandCatalog.candidates in Packages/Shared/CmuxAgentBrands (both run the
/// generated AGENT_BRAND_RESOLUTION_CASES).
function candidates(raw: string): string[] {
  const id = raw.trim().toLowerCase();
  if (!id) return [];
  const out = [id];
  const add = (value: string | undefined) => {
    if (value && !out.includes(value)) out.push(value);
  };
  add(id.split(":").filter(Boolean).at(-1));
  add(id.split("/").filter(Boolean).at(-1));
  const word = out.at(-1)!.split(/\s+/).find(Boolean);
  add(word);
  add(word?.split(/[-_.]/).find(Boolean));
  return out;
}

/// The brand for an agent, harness, alias, binary path or provider id ("claude-sr",
/// "acp:claude", "/usr/local/bin/codex", "xai"), or undefined when it has no mark. The
/// first candidate the catalog knows decides, including ids known to have no mark.
export function agentBrand(agent: string | undefined): AgentBrandId | undefined {
  if (!agent) return undefined;
  for (const candidate of candidates(agent))
    if (Object.hasOwn(AGENT_BRAND_LOOKUP, candidate)) return AGENT_BRAND_LOOKUP[candidate] ?? undefined;
  return undefined;
}

/// The mark to draw for an agent id, or undefined for the generic glyph.
export function agentBrandSpec(agent: string | undefined): AgentBrandSpec | undefined {
  const brand = agentBrand(agent);
  return brand ? AGENT_BRANDS[brand] : undefined;
}
