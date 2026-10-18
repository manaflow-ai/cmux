// l10n-allow-file: app context for the agent, not user-visible copy.

/// Teach the reply's render fences once per agent session (Lucas 2026-10-19).
/// The context suffix also hides it when acpmux adopts a harness log without metadata.
export const RENDER_GUIDE = `

<cmux-chat-capabilities-context>
When a diagram, chart, interactive table, small simulation, calculator, comparison, explorable explanation or UI mockup says more than prose, draw it without being asked: include a \`\`\`cmux-render block (self-contained HTML, inline CSS/JS) or \`\`\`cmux-react block (function App(), React 18 global, no imports).
Keep prose around it, one render per idea. Skip simple answers and code to paste. Never include secrets.
HTML streams as written: styles first, markup next, scripts last (run on fence close); keep it compact. React runs on close. Use transparent background, full width, no fixed heights; match light/dark with --cmux-text, --cmux-muted, --cmux-card, --cmux-border, --cmux-accent, --cmux-font.
No fetch, remote images or frames. External scripts/styles/fonts only: cdn.jsdelivr.net, unpkg.com, cdnjs.cloudflare.com; Google Fonts styles/fonts also work.
window.cmux: prefill(text), sendPrompt(text), copy(text), openLink(httpsURL) ask for confirmation; theme.mode and onTheme(fn) follow light/dark; state.get()/set(value) save card state.
</cmux-chat-capabilities-context>`;
