import type { ValidationResult } from "./validate";

const number = (value: number | null | undefined) =>
  typeof value === "number" && Number.isFinite(value) ? value.toFixed(1) : "missing";

/** Render a reviewable PR report without hiding an incomplete or failed gate. */
export function formatReport(result: ValidationResult, pullRequest?: string): string {
  const title = pullRequest ? `Web UI performance gate (PR #${pullRequest})` : "Web UI performance gate";
  const lines = [`## ${title}`, ""];
  if (result.head) lines.push(`- head: \`${result.head}\``);
  if (result.base) lines.push(`- PR base head: \`${result.base}\``);
  if (result.baselineHead) lines.push(`- measured baseline head: \`${result.baselineHead}\``);
  lines.push(`- verdict: **${result.ok ? "pass" : "fail"}**`, "");

  if (result.rows.length) {
    lines.push(
      `| case | p50 (ms) | p95 (ms) | max (ms) | baseline p95 | allowed p95 | status | fixing PR |`,
      `| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |`,
    );
    for (const row of result.rows) {
      lines.push(
        `| ${row.id} | ${number(row.p50)} | ${number(row.p95)} | ${number(row.max)} | ${number(row.baselineP95)} | ${number(row.allowedP95)} | ${row.status} | ${row.fixingPr ?? ""} |`,
      );
    }
    lines.push("");
  }

  if (result.errors.length) {
    lines.push("### Gate errors", "", ...result.errors.map((error) => `- ${error}`), "");
  }
  if (result.warnings.length) {
    lines.push("### Notes", "", ...result.warnings.map((warning) => `- ${warning}`), "");
  }
  return `${lines.join("\n")}\n`;
}
