/** Recaps arrive as plain sentences or a short list. Keep their words as compact bullet points. */
export function recapPoints(text: string, language: string): string[] {
  const lines = text
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
  const bullet = /^(?:[-*•]|\d+[.)])\s+/;
  if (lines.some((line) => bullet.test(line))) return lines.map((line) => line.replace(bullet, "")).filter(Boolean);
  const sentences = new Intl.Segmenter(language, { granularity: "sentence" });
  return lines.flatMap((line) => [...sentences.segment(line)].map(({ segment }) => segment.trim()).filter(Boolean));
}

export function recapHeight(text: string, width: number, lineHeight: number, language: string, lead = true): number {
  const points = recapPoints(text, language);
  const columns = Math.max(24, Math.floor(width / 8) - 6);
  const lines = points.reduce((total, point) => total + Math.max(1, Math.ceil(point.length / columns)), 0);
  return 24 + (lines + (lead ? 1 : 0)) * lineHeight + Math.max(0, points.length - 1) * 4 + (lead ? 4 : 0);
}
