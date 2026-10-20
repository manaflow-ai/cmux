export type MarkdownFence = { marker: string; lang: string };

/// A shorter fence or a different delimiter inside code is still source text.
export function openingFence(line: string): MarkdownFence | undefined {
  const match = /^\s*(`{3,}|~{3,})(.*)$/.exec(line);
  if (!match || (match[1]!.startsWith("`") && match[2]!.includes("`"))) return;
  return { marker: match[1]!, lang: match[2]!.trim().split(/\s/)[0] || "text" };
}

export function closesFence(line: string, fence: MarkdownFence): boolean {
  const marker = /^\s*(`+|~+)[ \t]*$/.exec(line)?.[1];
  return !!marker && marker[0] === fence.marker[0] && marker.length >= fence.marker.length;
}

export function advanceFence(fence: MarkdownFence | undefined, line: string): MarkdownFence | undefined {
  return fence ? (closesFence(line, fence) ? undefined : fence) : openingFence(line);
}
