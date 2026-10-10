// l10n-allow-file: gallery fixtures (sample render HTML), not shipped UI.
// HTML an agent might pass the render tool (acpmux conversation/renderCall.ts): small pages in the
// frame's theme variables (`var(--cmux-text)` and the rest, RenderCard.tsx), with no library.
// Pure data, as gallery files need.
import type { AcpmuxActivity } from "../../agent-session/acpmux/model";
import { tool } from "./acpmux";

/** A completed render tool call with `input` (`html`, `title?`, `recommended?`). */
export const renderTool = (input: { html: string; title?: string; recommended?: boolean }): AcpmuxActivity =>
  tool("mcp__cmux-render__render", "other", "completed", { inputSummary: JSON.stringify(input) });

/** A bar chart of median keystroke-to-paint per layout. */
export function latencyChart(): string {
  const bars: [string, number, number][] = [
    ["1 pane", 7.8, 7.7],
    ["2 splits", 7.9, 7.9],
    ["4 splits", 8.1, 8.2],
    ["8 splits", 8.6, 8.9],
  ];
  const scale = (ms: number) => Math.round(ms * 16);
  const rows = bars
    .map(([label, branch, main], index) => {
      const y = 14 + index * 34;
      return (
        `<text x="0" y="${y + 13}" class="l">${label}</text>` +
        `<rect x="76" y="${y}" width="${scale(branch)}" height="11" rx="2" class="b"/>` +
        `<rect x="76" y="${y + 13}" width="${scale(main)}" height="7" rx="2" class="m"/>` +
        `<text x="${82 + scale(branch)}" y="${y + 10}" class="v">${branch.toFixed(1)}</text>`
      );
    })
    .join("");
  return (
    "<style>body{padding:14px 16px}svg{display:block;width:420px;max-width:100%;height:auto;font:12px var(--cmux-font)}" +
    ".l{fill:var(--cmux-muted)}.v{fill:var(--cmux-text)}.b{fill:#3b82f6}.m{fill:var(--cmux-border)}</style>" +
    `<svg viewBox="0 0 420 148" role="img" aria-label="Median keystroke-to-paint by layout">${rows}</svg>`
  );
}

/** A nested list with its sub-items `gap` px under their parent. */
export function listMock(gap: number): string {
  const item = (text: string) => `<li>${text}<ul><li>First detail</li><li>Second detail</li></ul></li>`;
  return (
    `<style>body{padding:12px 16px}ul{margin:0;padding-left:18px}li{line-height:20px}` +
    `li ul{margin-top:${gap}px;color:var(--cmux-muted)}li+li{margin-top:6px}</style>` +
    `<ul>${item("Install the app")}${item("Open a workspace")}${item("Start an agent")}</ul>`
  );
}

/** A pricing card in `accent`, `rows` feature lines tall. */
export function pricingCard(plan: string, price: string, accent: string, rows = 4): string {
  const features = Array.from({ length: rows }, (_, index) => `<li>Feature ${index + 1}</li>`).join("");
  return (
    `<style>body{padding:16px}.c{border:1px solid var(--cmux-border);border-radius:12px;padding:16px}` +
    `h2{margin:0;font-size:15px}.p{font-size:26px;font-weight:600;margin:8px 0}ul{margin:0;padding-left:18px;color:var(--cmux-muted)}` +
    `li{line-height:22px}button{margin-top:12px;border:0;border-radius:8px;padding:8px 14px;color:#fff;background:${accent};font:inherit}</style>` +
    `<div class="c"><h2>${plan}</h2><div class="p">${price}</div><ul>${features}</ul><button>Choose ${plan}</button></div>`
  );
}
