const codeStyles = `
:root {
  color-scheme: light dark;
  --cmux-code-canvas: transparent;
  --cmux-code-font-mono: "SFMono-Regular", "SF Mono", ui-monospace, Menlo, monospace;
  --cmux-code-font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  --cmux-ghostty-background: light-dark(#fcfcfc, #0e0e0e);
  --cmux-ghostty-foreground: light-dark(#262626, #f5f5f5);
  --cmux-ghostty-primary: light-dark(#526fff, #6073cc);
  font-size: 14px;
}
html, body, #root { width: 100%; height: 100%; margin: 0; }
html, body, #root { background: transparent; }
body {
  color: var(--cmux-ghostty-foreground);
  font-family: var(--cmux-code-font-sans);
  overflow: hidden;
}
.code-launcher {
  background: var(--cmux-code-canvas);
  height: 100%;
  width: 100%;
}
.code-launcher__topbar,
.code-launcher__composer-footer {
  align-items: center;
  display: flex;
}
.code-launcher__line {
  background: color-mix(in srgb, var(--cmux-ghostty-foreground) 18%, transparent);
  border-radius: 999px;
  display: block;
  height: 0.45rem;
}
.code-launcher__line--title { width: 4.75rem; }
.code-launcher__main {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-width: 0;
}
.code-launcher__topbar {
  border-bottom: 1px solid color-mix(in srgb, var(--cmux-ghostty-foreground) 9%, transparent);
  box-sizing: border-box;
  gap: 0.65rem;
  height: 3rem;
  padding: 0 1rem;
}
.code-launcher__topbar-dot,
.code-launcher__composer-dot {
  background: color-mix(in srgb, var(--cmux-ghostty-foreground) 24%, transparent);
  border-radius: 999px;
  display: block;
  height: 0.55rem;
  width: 0.55rem;
}
.code-launcher__stage { flex: 1; min-height: 0; }
.code-launcher__composer {
  background: color-mix(in srgb, var(--cmux-ghostty-background) 82%, transparent);
  border: 1px solid color-mix(in srgb, var(--cmux-ghostty-foreground) 14%, transparent);
  border-radius: 0.7rem;
  box-shadow: 0 8px 24px rgb(0 0 0 / 10%);
  box-sizing: border-box;
  margin: 0 auto 1.35rem;
  min-height: 5.25rem;
  padding: 0.95rem;
  width: min(42rem, calc(100% - 3rem));
}
.code-launcher__composer > .code-launcher__line { width: 38%; }
.code-launcher__composer-footer {
  gap: 0.55rem;
  margin-top: 1.8rem;
}
.code-launcher__composer-send {
  background: color-mix(in srgb, var(--cmux-ghostty-primary) 72%, transparent);
  border-radius: 0.45rem;
  height: 1.65rem;
  margin-left: auto;
  width: 1.65rem;
}
`;

export function createCodeMountNotifier(postMessage: (message: unknown) => void): () => void {
  let mounted = false;
  return () => {
    if (mounted) return;
    mounted = true;
    postMessage({ type: "mount" });
  };
}

export function mountCodeSurface(rootElement: HTMLElement): void {
  const document = rootElement.ownerDocument;
  const style = document.createElement("style");
  style.dataset.cmuxWebviewStyle = "code";
  style.textContent = codeStyles;
  document.head.append(style);

  const launcher = document.createElement("div");
  launcher.className = "code-launcher";
  launcher.ariaHidden = "true";
  launcher.innerHTML = `
    <section class="code-launcher__main">
      <header class="code-launcher__topbar">
        <span class="code-launcher__topbar-dot"></span>
        <span class="code-launcher__line code-launcher__line--title"></span>
      </header>
      <div class="code-launcher__stage"></div>
      <div class="code-launcher__composer">
        <span class="code-launcher__line"></span>
        <div class="code-launcher__composer-footer">
          <span class="code-launcher__composer-dot"></span>
          <span class="code-launcher__composer-dot"></span>
          <span class="code-launcher__composer-send"></span>
        </div>
      </div>
    </section>
  `;
  rootElement.replaceChildren(launcher);

  createCodeMountNotifier((message) => {
    window.webkit?.messageHandlers?.cmuxCode?.postMessage(message);
  })();
}

if (typeof document !== "undefined") {
  const rootElement = document.getElementById("root");
  if (!rootElement) throw new Error("Missing cmux webview root");
  mountCodeSurface(rootElement);
}
