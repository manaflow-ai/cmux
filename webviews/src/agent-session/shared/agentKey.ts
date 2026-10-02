/// The agent a harness id names: its first word, lowercased. acpmux names harnesses
/// by config id, so variants share their agent ("claude-sr" is "claude").
export function agentKey(id: string | undefined): string | undefined {
  const word = id?.split(/[-_\s]+/).find(Boolean);
  return word ? word.toLowerCase() : undefined;
}
