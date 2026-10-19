type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

export function invalidAgentParams(_params: SearchParams): string[] {
  return [];
}

export function agentNativeHref(_params: SearchParams): string | null {
  return null;
}
