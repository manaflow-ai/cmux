const codeStyles = `
:root {
  color-scheme: light dark;
  --cmux-ghostty-background: light-dark(#fcfcfc, #0e0e0e);
  --cmux-ghostty-foreground: light-dark(#262626, #f5f5f5);
  --cmux-ghostty-primary: light-dark(#526fff, #6073cc);
  --cmux-code-font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
}
html, body, #root { width: 100%; height: 100%; margin: 0; }
body {
  background: var(--cmux-ghostty-background);
  color: var(--cmux-ghostty-foreground);
  font-family: var(--cmux-code-font-family);
}
.code-launcher {
  align-items: center;
  display: flex;
  height: 100%;
  justify-content: center;
}
.code-launcher__spinner {
  animation: code-launcher-spin 850ms linear infinite;
  border: 2px solid color-mix(in srgb, var(--cmux-ghostty-foreground) 16%, transparent);
  border-radius: 999px;
  border-top-color: var(--cmux-ghostty-primary);
  height: 18px;
  width: 18px;
}
@keyframes code-launcher-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .code-launcher__spinner { animation: none; } }
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
  const style = document.createElement("style");
  style.dataset.cmuxWebviewStyle = "code";
  style.textContent = codeStyles;
  document.head.append(style);

  const launcher = document.createElement("div");
  launcher.className = "code-launcher";
  const spinner = document.createElement("div");
  spinner.ariaLabel = "Code";
  spinner.className = "code-launcher__spinner";
  spinner.role = "status";
  launcher.append(spinner);
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
