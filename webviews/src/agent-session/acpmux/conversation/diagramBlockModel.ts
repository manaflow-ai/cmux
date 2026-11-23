import { chartSpec } from "./chartSpec";

const CHART_LANGUAGES = new Set(["vega-lite", "vega"]);

/// Whether a finished fence draws as a chart or diagram: mermaid with source, a chart language and a
/// JSON object spec, or a ```chart fence whose small JSON compiles to a chart (chartSpec.ts).
export function isChart(lang: string, code: string): boolean {
  const language = lang.toLowerCase();
  if (language === "mermaid") return code.trim() !== "";
  if (language === "chart") return chartSpec(code) !== undefined;
  if (!CHART_LANGUAGES.has(language)) return false;
  try {
    const spec: unknown = JSON.parse(code);
    return typeof spec === "object" && spec !== null && !Array.isArray(spec);
  } catch {
    return false;
  }
}
