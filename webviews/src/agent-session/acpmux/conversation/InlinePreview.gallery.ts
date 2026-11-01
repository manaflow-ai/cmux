// l10n-allow-file: gallery fixtures (sample prompts, replies and documents), not shipped UI.
// A reply's closed ```html or ```svg fence drawn inline as its document (InlinePreview.tsx), in a frame
// sandboxed with allow-scripts and no same-origin, behind a policy with no network. Code shows the
// source card (Copy stays); Open puts it in the side panel. An open fence stays plain code, and a
// document that carries script waits for Run.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const fence = (lang: string, code: string, close = true) => "```" + lang + "\n" + code + (close ? "\n```" : "\n");

const reply = (prompt: string, text: string, streaming = false) =>
  chat(
    streaming
      ? [user(prompt, 6), assistant(text, 0.5, { streaming: true })]
      : [user(prompt, 6), assistant(text, 5), summary(5, { status: "completed", durationMs: 24_000 })],
  );

const bars: [string, number][] = [
  ["Mon", 42],
  ["Tue", 58],
  ["Wed", 35],
  ["Thu", 71],
  ["Fri", 64],
];

/// A bar chart as one SVG image: bars, values and day labels, in the chat's text colour.
const barChart = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 200" width="360" height="200" font-family="system-ui" font-size="11">
  <title>Builds per day</title>
  <line x1="30" y1="170" x2="350" y2="170" stroke="currentColor" stroke-opacity="0.3"/>
${bars
  .map(([day, value], index) => {
    const x = 44 + index * 62;
    const height = value * 2;
    return `  <rect x="${x}" y="${170 - height}" width="36" height="${height}" rx="4" fill="#3b82f6"/>
  <text x="${x + 18}" y="${164 - height}" text-anchor="middle" fill="currentColor">${value}</text>
  <text x="${x + 18}" y="186" text-anchor="middle" fill="currentColor" fill-opacity="0.6">${day}</text>`;
  })
  .join("\n")}
</svg>`;

const rows: [string, number, number][] = [
  ["1st year", 5, 7],
  ["2nd year", 5, 9],
  ["3rd year", 6, 8],
];

/// A study-guide section: a table of hours and the same numbers as a line chart, side by side.
const tableAndChart = `<!doctype html>
<html>
<head><title>Study hours by year</title>
<style>
  .grid { display: flex; gap: 20px; align-items: flex-start; flex-wrap: wrap; }
  th, td { padding: 4px 10px; text-align: right; }
  th:first-child, td:first-child { text-align: left; }
</style></head>
<body>
  <h3>Study hours by year</h3>
  <div class="grid">
    <table>
      <thead><tr><th>Year</th><th>Psych</th><th>Neuro</th></tr></thead>
      <tbody>
${rows.map(([year, psych, neuro]) => `        <tr><td>${year}</td><td>${psych}</td><td>${neuro}</td></tr>`).join("\n")}
      </tbody>
    </table>
    <svg viewBox="0 0 240 140" width="240" height="140" font-size="10" font-family="system-ui">
      <line x1="20" y1="120" x2="230" y2="120" stroke="currentColor" stroke-opacity="0.3"/>
      <polyline fill="none" stroke="#3b82f6" stroke-width="2" points="${rows.map(([, psych], index) => `${40 + index * 80},${120 - psych * 10}`).join(" ")}"/>
      <polyline fill="none" stroke="#ef4444" stroke-width="2" stroke-dasharray="4 3" points="${rows.map(([, , neuro], index) => `${40 + index * 80},${120 - neuro * 10}`).join(" ")}"/>
${rows.map(([year], index) => `      <text x="${40 + index * 80}" y="134" text-anchor="middle" fill="currentColor" fill-opacity="0.6">${year}</text>`).join("\n")}
      <text x="230" y="20" text-anchor="end" fill="#3b82f6">Psych</text>
      <text x="230" y="34" text-anchor="end" fill="#ef4444">Neuro</text>
    </svg>
  </div>
</body>
</html>`;

const counter = `<title>Counter</title>
<button onclick="this.textContent = Number(this.textContent) + 1">0</button>`;

export default agentPaneEntry({
  id: "agent-pane.inline-preview",
  title: "Inline HTML and SVG preview",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/InlinePreview.tsx",
    "agent-session/acpmux/conversation/previewDocument.ts",
  ],
  variants: {
    "svg-bar-chart": {
      note: "An SVG bar chart in a reply draws as the chart.",
      snapshot: reply(
        "Chart builds per day this week",
        `Builds per day:\n\n${fence("svg", barChart)}\n\nThursday peaked at 71.`,
      ),
    },
    "html-table-chart": {
      note: "An HTML section with a table and the same numbers as a line chart.",
      snapshot: reply(
        "Make a study-guide section for these hours",
        `Here is the section:\n\n${fence("html", tableAndChart)}\n\nNeuro rises in the 2nd year.`,
      ),
    },
    code: {
      note: "Code swaps the preview for the source card, which keeps Copy.",
      snapshot: reply("Chart builds per day this week", `Builds per day:\n\n${fence("svg", barChart)}`),
      play: async (ctx: PlayContext) => {
        await ctx.click({ role: "button", name: "Code" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-codeblock"));
      },
    },
    streaming: {
      note: "A fence still arriving stays plain code: nothing renders until it closes.",
      snapshot: reply("Chart builds per day this week", `Builds per day:\n\n${fence("svg", barChart, false)}`, true),
    },
    scripted: {
      note: "A document with script shows its source until Run.",
      snapshot: reply("Make a counter", fence("html", counter)),
    },
  },
});
