const DETAIL_MAX_LENGTH = 200;

/**
 * Provider or database prose made safe to store in a snapshot and show to
 * staff: bounded, whitespace-collapsed, with anything token-shaped removed.
 */
export function sanitizeDetail(text: string): string {
  return text
    .replace(/\b(bearer|token|key|secret|password)[=:\s]+\S+/gi, "$1=[redacted]")
    .replace(/\b[A-Za-z0-9_-]{32,}\b/g, "[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, DETAIL_MAX_LENGTH);
}
