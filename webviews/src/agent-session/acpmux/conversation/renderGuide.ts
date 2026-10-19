// l10n-allow-file: app context for the agent, not user-visible copy.
import { labOn } from "../labs";

/// Teach the reply's render fences once per agent session (Lucas 2026-10-19).
const INTRO =
  "Draw charts, diagrams, interactive tables, calculators and explorable explanations inline when they help. Use a ```cmux-render block (HTML/CSS/JS) or ```cmux-react (function App(), React 18 global, no imports). Fences are the fast streaming path: HTML draws as written, scripts and React run on close. Tool-based renders: check it with render_preview, then show it with render. Preview returns an image and diagnostics at reply width; width:390 checks phones. Never include secrets. Pass the HTML inline in the fence or the tool call; never write it to a file, and use these instead of a separate visualize or artifact skill. Skip simple answers and code to paste.";
const LAYOUT =
  "Flush with reply text: no outer card, banner, background or horizontal body padding. Fluid width, content height; never 100vh or height:100%. Inset surfaces: 16px padding, var(--cmux-radius) corners. Charts need pixel heights. Short styles first, markup next, scripts last.";
const BRIDGE =
  "window.cmux: prefill(text), sendPrompt(text), copy(text), openLink(httpsURL) require confirmation and reject when declined; catch rejections. theme.mode/onTheme(fn) follow light/dark; state.get()/set(value) persist per render. No fetch, remote images or frames. Scripts/styles: cdn.jsdelivr.net, unpkg.com, cdnjs.cloudflare.com; Google Fonts supported.";
const KIT =
  "Native defaults; .stack/.row/.grid, .panel, .stat (strong + small), .badge/.muted, .segmented (labels with radios). Tokens (--cmux-): text, muted, bg, card, border, accent, success, warning, danger, chart-1 through chart-6, radius, space-1 through space-4, font, font-mono. cmux.chart(element,{type:'line'|'area'|'bar'|'donut'|'pie',height:220,labels:[],series:[{name,values:[]}]}); or data-cmux-chart='JSON'. Follow-ups: button data-cmux-prompt or data-cmux-prefill, also confirmed.";
const wrap = (kit: boolean, preview = true) =>
  `\n\n<cmux-chat-capabilities-context>\n${preview ? INTRO : INTRO.replace(/ Tool-based renders:.*?Never include secrets\./, " Never include secrets.")}\n${LAYOUT}\n${kit ? KIT : "Theme tokens: --cmux-text, --cmux-muted, --cmux-card, --cmux-border, --cmux-accent, --cmux-font."}\n${BRIDGE}\n</cmux-chat-capabilities-context>`;
export const RENDER_GUIDE = wrap(true);
export const renderGuide = () => wrap(labOn("renderKit"), labOn("renderPreview"));
