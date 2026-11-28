interface BrowserNavigator {
  userAgentData?: { platform?: string };
  platform?: string;
  userAgent?: string;
}

export function browserClientName(source: BrowserNavigator = navigator): string | undefined {
  const value = source.userAgentData?.platform || source.platform || source.userAgent;
  const normalized = value?.replace(/\s+/g, " ").trim();
  return normalized ? [...normalized].slice(0, 64).join("") : undefined;
}
