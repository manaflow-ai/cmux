// l10n-allow-file: diagnostics returned to the agent, not pane copy.

/// Runs only inside the opaque frame, before any agent script (Lucas 2026-10-19).
export function renderPreviewDiagnostics(): string {
  return `<script>(${installDiagnostics.toString()})();</script>`;
}

function installDiagnostics() {
  const messages: { level: string; message: string }[] = [];
  const record = (level: string, value: unknown) => {
    if (messages.length < 50) messages.push({ level, message: String(value).slice(0, 500) });
  };
  // WebKit redacts errors from opaque-origin script callbacks. Capture before rethrowing.
  const timeout = window.setTimeout.bind(window);
  window.setTimeout = ((callback: TimerHandler, delay?: number, ...args: unknown[]) => {
    if (typeof callback !== "function") return timeout(callback, delay, ...args);
    return timeout(
      (...values: unknown[]) => {
        try {
          return callback(...values);
        } catch (error) {
          record("exception", error instanceof Error ? error.message : error);
          throw error;
        }
      },
      delay,
      ...args,
    );
  }) as typeof window.setTimeout;
  let previewState: unknown = null;
  const unavailable = () => Promise.reject(new Error("App actions are unavailable during preview"));
  Object.assign((window as unknown as { cmux: object }).cmux, {
    prefill: unavailable,
    sendPrompt: unavailable,
    copy: unavailable,
    openLink: unavailable,
    state: {
      get: () => Promise.resolve(previewState),
      set: (value: unknown) => { previewState = value; return Promise.resolve(null); },
    },
  });
  for (const level of ["warn", "error"] as const) {
    const original = console[level];
    console[level] = (...args: unknown[]) => {
      record(level, args.map((value) => String(value)).join(" "));
      original.apply(console, args);
    };
  }
  window.addEventListener(
    "error",
    (event) => {
      if (event instanceof ErrorEvent) record("exception", event.message || "Script error");
      else record("warn", "Resource failed to load");
    },
    true,
  );
  document.addEventListener("securitypolicyviolation", (event) =>
    record("warn", "CSP blocked " + event.blockedURI),
  );
  window.addEventListener("unhandledrejection", (event) =>
    record("exception", event.reason?.message || event.reason),
  );
  document.addEventListener(
    "cmux-render-settled",
    async () => {
      await document.fonts?.ready;
    // Capture the kit's final appearance, rather than the middle of its entrance fade.
    const animations = document.getAnimations?.() ?? [];
    await Promise.all(animations.filter((animation) => {
      const end = animation.effect?.getComputedTiming().endTime;
      return typeof end === "number" && Number.isFinite(end) && end <= 1000;
    }).slice(0, 100).map((animation) => animation.finished.catch(() => {})));
      await new Promise(requestAnimationFrame);
      await new Promise(requestAnimationFrame);
      // A React commit can land after the last ResizeObserver callback.
      (window as unknown as { __cmuxMeasureRenderContent?: () => void }).__cmuxMeasureRenderContent?.();
      const warnings: string[] = [];
      const width = innerWidth;
      const body = document.body;
      const elements = Array.from(body.querySelectorAll("*")).slice(0, 5000);
      if (document.documentElement.scrollWidth > width + 1 || body.scrollWidth > width + 1)
        warnings.push("Horizontal overflow");
      let oversized = 0,
        tiny = 0;
      for (const element of elements) {
        const rect = element.getBoundingClientRect();
        if (!rect.width || !rect.height) continue;
        let contained = false;
        for (let parent = element.parentElement; parent && parent !== body; parent = parent.parentElement) {
          if (/^(auto|hidden|scroll|clip)$/.test(getComputedStyle(parent).overflowX)) {
            contained = true;
            break;
          }
        }
        if (!contained && rect.width > width + 1) oversized++;
        if (
          Array.from(element.childNodes).some(
            (node) => node.nodeType === 3 && node.textContent?.trim(),
          ) &&
          parseFloat(getComputedStyle(element).fontSize) < 10
        )
          tiny++;
      }
      if (oversized) warnings.push(oversized + " elements wider than column");
      if (tiny) warnings.push(tiny + " elements with text smaller than 10px");
      if (
        Array.from(document.querySelectorAll("style,[style]")).some((el) =>
          /\b100\s*(?:d|s|l)?vh\b/i.test(
            el.tagName === "STYLE" ? el.textContent || "" : el.getAttribute("style") || "",
          ),
        )
      )
        warnings.push("100vh usage can cause frame height feedback");
      const visible = elements.filter((el) => !/^(SCRIPT|STYLE|LINK|META)$/.test(el.tagName));
      const bottom = Math.max(0, ...visible.map((el) => el.getBoundingClientRect().bottom));
      if (!bottom && !body.textContent?.trim()) warnings.push("Zero-height page");
      const missingImages = Array.from(document.images)
        .filter((img) => !img.complete || !img.naturalWidth)
        .slice(0, 20)
        .map((img) => (img.getAttribute("src") || "(no src)").slice(0, 200));
      parent.postMessage(
        { type: "cmux-render-preview-result", height: (window as unknown as { __cmuxRenderContentHeight?: number }).__cmuxRenderContentHeight ?? Math.ceil(body.getBoundingClientRect().height), consoleMessages: messages, warnings, missingImages },
        "*",
      );
    },
    { once: true },
  );
}
