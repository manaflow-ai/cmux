// l10n-allow-file: frame styles, with no user-facing copy.

/// The first layer lets agent styles, including layered utilities, win (Lucas 2026-10-19).
export const RENDER_KIT_CSS = `
@layer cmux {
:where(:root){--cmux-surface:var(--cmux-card);--cmux-font-mono:var(--cmux-mono);--cmux-success:light-dark(#287348,#79bb91);--cmux-warning:light-dark(#936317,#d2ac65);--cmux-danger:light-dark(#b03e42,#e18a8c);--cmux-chart-1:light-dark(#007aff,#0a84ff);--cmux-chart-2:light-dark(#34c759,#30d158);--cmux-chart-3:light-dark(#ff9500,#ff9f0a);--cmux-chart-4:light-dark(#af52de,#bf5af2);--cmux-chart-5:light-dark(#ff2d55,#ff375f);--cmux-chart-6:light-dark(#32ade6,#64d2ff)}
:where(*, *::before, *::after){box-sizing:border-box}
:where(html,body){background:transparent}
:where(body){margin:4px 0;font:var(--cmux-chat-size)/1.625 var(--cmux-font);color:var(--cmux-text)}
:where(h1,h2,h3,h4){font-weight:600;line-height:1.3;letter-spacing:-.015em;margin:0 0 8px}
:where(h1){font-size:calc(var(--cmux-size-heading) * 1.18)}:where(h2){font-size:var(--cmux-size-heading)}:where(h3){font-size:var(--cmux-size-title)}:where(h4){font-size:var(--cmux-size-body)}
:where(p,ul,ol,pre,figure,table,details){margin:0 0 12px}:where(ul,ol){padding-left:20px}:where(li+li){margin-top:4px}
:where(strong){font-weight:600}:where(small,figcaption){font-size:var(--cmux-size-detail);color:var(--cmux-muted)}
:where(a){color:var(--cmux-accent);text-underline-offset:3px}:where(code,kbd,pre){font-family:var(--cmux-font-mono)}
:where(code,kbd){font-size:.92em;background:var(--cmux-control);padding:2px 4px;border-radius:3px}:where(kbd){border:1px solid var(--cmux-border)}
:where(pre){padding:12px;background:var(--cmux-surface);border:1px solid var(--cmux-border);border-radius:var(--cmux-radius);overflow:auto}:where(pre code){padding:0;background:none}
:where(hr){border:0;border-top:1px solid var(--cmux-border);margin:16px 0}
:where(table){width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}:where(th,td){padding:8px 12px 8px 0;text-align:left;border-bottom:1px solid var(--cmux-border)}:where(th){color:var(--cmux-muted);font-size:var(--cmux-size-detail);font-weight:500}:where(td[data-numeric],th[data-numeric]){text-align:right}
:where(button,input,select,textarea){font:inherit;color:inherit;accent-color:var(--cmux-accent)}
:where(button,select,input:not([type=range],[type=checkbox],[type=radio]),textarea){min-height:28px;padding:4px 9px;border:.5px solid var(--cmux-border);border-radius:var(--cmux-radius);background:var(--cmux-surface);box-shadow:none}
:where(button){cursor:default;font-weight:500}:where(button:hover){background:var(--cmux-control-hover)}:where(button:active){background:var(--cmux-control)}:where(button[data-variant=primary]){background:var(--cmux-accent);color:var(--cmux-on-accent);border-color:transparent}:where(button:disabled,input:disabled){opacity:.5}
:where(textarea){resize:vertical;max-width:100%}:where(input[type=range]){min-width:60px;margin:0;height:24px}:where(input[type=checkbox],input[type=radio]){margin:0 5px 0 0;vertical-align:middle}
:where(button:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible,summary:focus-visible){outline:2px solid color-mix(in srgb,var(--cmux-accent) 65%,transparent);outline-offset:2px}
:where(details){border-bottom:.5px solid var(--cmux-border);padding:8px 0}:where(summary){cursor:default;font-weight:500}:where(details[open] summary){margin-bottom:8px}
:where(progress,meter){accent-color:var(--cmux-accent);height:6px;width:100%}:where(figure){margin-inline:0}:where(figcaption){margin-top:8px}:where(svg text){font-family:inherit}
:where(.stack){display:flex;flex-direction:column;gap:16px}:where(.row){display:flex;align-items:center;flex-wrap:wrap;gap:8px}:where(.grid){display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,160px),1fr));gap:12px}:where(.stack>*,.row>*,.grid>*){margin-block:0;min-width:0}
:where(.panel){padding:16px;border:.5px solid var(--cmux-border);border-radius:var(--cmux-radius);background:var(--cmux-surface)}
:where(.stat){display:flex;flex-direction:column;gap:2px;font-variant-numeric:tabular-nums}:where(.stat strong){font-size:calc(var(--cmux-size-heading) * 1.53);font-weight:600;letter-spacing:-.025em;line-height:1.25}:where(.stat small){font-size:var(--cmux-size-detail)}
:where(.badge){display:inline-flex;align-items:center;padding:2px 6px;border-radius:4px;background:var(--cmux-control);color:var(--cmux-muted);font-size:var(--cmux-size-caption);font-weight:500}:where(.muted){color:var(--cmux-muted)}
:where(.segmented){display:inline-flex;gap:2px;padding:2px;background:var(--cmux-control);border:.5px solid var(--cmux-border);border-radius:var(--cmux-radius)}:where(.segmented label){position:relative;padding:3px 10px;border-radius:4px;cursor:default}:where(.segmented label:has(input:checked)){background:var(--cmux-canvas)}:where(.segmented input){position:absolute;opacity:0;width:1px;height:1px}:where(.segmented label:has(input:focus-visible)){outline:2px solid var(--cmux-accent)}
:where([data-cmux-chart]:not(:has(svg))){min-height:220px}
@media(prefers-reduced-motion:reduce){:where(*){animation:none;transition:none;scroll-behavior:auto}}
}
`.replace(/\n/g, "");
