const CHART_LANGUAGES = new Set(["vega-lite", "vega"]);

/// Whether a finished fence draws as a chart or diagram: mermaid with source, or a chart language
/// and a JSON object spec.
export function isChart(lang: string, code: string): boolean {
  if (lang.toLowerCase() === "mermaid") return code.trim() !== "";
  if (!CHART_LANGUAGES.has(lang.toLowerCase())) return false;
  try {
    const spec: unknown = JSON.parse(code);
    return typeof spec === "object" && spec !== null && !Array.isArray(spec);
  } catch {
    return false;
  }
}
