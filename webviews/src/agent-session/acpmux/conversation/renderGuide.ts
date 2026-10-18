// l10n-allow-file: app context for the agent, not user-visible copy.
import { labOn } from "../labs";

/// Teach the reply's render fences once per agent session (Lucas 2026-10-19).
const INTRO =
  "This chat draws HTML inline in your reply. When a chart, diagram, interactive table, small simulation, calculator, comparison or explorable explanation says more than prose, draw it without being asked: a ```cmux-render block (self-contained HTML/CSS/JS) or ```cmux-react (function App(), React 18 global, no imports). The reader sees it in place, so don't announce it; keep prose for what it doesn't show. One render per idea; skip simple answers and code to paste. Never include secrets.";
const LAYOUT =
  "The frame sits flush with reply text on the thread: no outer card, border, banner title, background or horizontal padding on html/body or the wrapper. Use fluid width and content height, never 100vh or height:100%. Inset surfaces need 16px padding and var(--cmux-radius) corners. Charts need pixel heights. Styles first (short), markup next, scripts last; HTML streams, scripts and React run on close.";
const BRIDGE =
  "window.cmux: prefill(text), sendPrompt(text), copy(text), openLink(httpsURL) require pane confirmation and reject when declined; catch rejections. theme.mode/onTheme(fn) follow light/dark; state.get()/set(value) persist per render. No fetch, remote images or frames. Scripts/styles: cdn.jsdelivr.net, unpkg.com, cdnjs.cloudflare.com; Google Fonts supported.";
const KIT =
  "Aim for a calm native look: clear hierarchy, few colors, real data labels. Lean on the built-in styles instead of writing CSS: native defaults, .stack/.row/.grid, .panel, .stat (strong + small), .badge/.muted, .segmented (labels with radios). Tokens (--cmux- prefix): text, muted, bg, surface, border, accent, success, warning, danger, chart-1 through chart-6, radius, space-1 through space-4, font, font-mono. cmux.chart(element,{type:'line'|'area'|'bar'|'donut'|'pie',height:220,labels:[],series:[{name,values:[]}]}); or data-cmux-chart='JSON'. Follow-ups: button data-cmux-prompt or data-cmux-prefill, also confirmed.";
const wrap = (kit: boolean) =>
  `\n\n<cmux-chat-capabilities-context>\n${INTRO}\n${LAYOUT}\n${kit ? KIT : "Theme tokens: --cmux-text, --cmux-muted, --cmux-card, --cmux-border, --cmux-accent, --cmux-font."}\n${BRIDGE}\n</cmux-chat-capabilities-context>`;
export const RENDER_GUIDE = wrap(true);
export const renderGuide = () => (labOn("renderKit") ? RENDER_GUIDE : wrap(false));
