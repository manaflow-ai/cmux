import { useCallback, useEffect, useState } from "react";
import type { Id } from "cmux/raw";
import { ATTACH_RECOVERY_STABLE_MS, attachRecoveryDelay } from "../lib/attachRecovery";
import { debounce } from "../lib/debounce";
import { nextFitSize, type TerminalSize } from "../lib/fit";
import { t } from "../i18n";
import { terminalTheme } from "../lib/terminalTheme";
import type { TerminalByteTransport, TerminalStream } from "../lib/terminalTransport";

type GhosttyModule = typeof import("ghostty-web");
type GhosttyInstance = Awaited<ReturnType<GhosttyModule["Ghostty"]["load"]>>;

/** The host element exposes the visible screen as text, for tests and the
 * latency script: the terminal paints to a canvas, so there is no DOM text. */
export interface GhosttyTerminalHost extends HTMLDivElement {
  cmuxScreenText?: () => string;
}

let loading: Promise<{ module: GhosttyModule; ghostty: GhosttyInstance }> | null = null;

/** ghostty-web and its wasm load once per page, only when a ghostty terminal
 * mounts, so the default bundle does not grow. The wasm is a file of the page
 * (`connect-src 'self'`), not the library's inline data: URL. */
function loadGhostty() {
  loading ??= (async () => {
    const [module, wasm] = await Promise.all([import("ghostty-web"), import("ghostty-web/ghostty-vt.wasm?url")]);
    const ghostty = await module.Ghostty.load(wasm.default);
    return { module, ghostty };
  })().catch((error: unknown) => {
    loading = null;
    throw error;
  });
  return loading;
}

interface GhosttyTerminalOptions {
  transport: TerminalByteTransport | null;
  surface: Id | null;
  focusOnMount?: boolean;
  onError(error: Error): void;
}

export function useGhosttyTerminal({ transport, surface, focusOnMount = false, onError }: GhosttyTerminalOptions) {
  const [host, setHost] = useState<GhosttyTerminalHost | null>(null);
  const [focused, setFocused] = useState(false);
  const terminalRef = useCallback((node: HTMLDivElement | null) => setHost(node), []);

  useEffect(() => {
    if (!host || !transport || surface === null) return;
    let cancelled = false;
    let dispose: (() => void) | null = null;
    const fail = (error: unknown) => {
      if (!cancelled) onError(error instanceof Error ? error : new Error(String(error)));
    };

    void (async () => {
      const { module, ghostty } = await loadGhostty();
      if (cancelled) return;
      const terminal = new module.Terminal({
        ghostty,
        convertEol: false,
        fontFamily: 'Menlo, "SFMono-Regular", Consolas, "Liberation Mono", monospace',
        fontSize: 13,
        theme: terminalTheme(host),
      });
      const fit = new module.FitAddon();
      terminal.loadAddon(fit);
      terminal.open(host);
      const screenText = () => {
        const buffer = terminal.buffer.active;
        const lines: string[] = [];
        for (let row = 0; row < terminal.rows; row++) {
          lines.push(buffer.getLine(buffer.viewportY + row)?.translateToString(true) ?? "");
        }
        return lines.join("\n");
      };
      Reflect.set(host, "cmuxScreenText", screenText);
      let writes = 0;
      // One attribute per written chunk: the latency script observes it as
      // the DOM path observes its grid (scripts/measure-in-browser.mjs).
      const write = (data: Uint8Array) =>
        new Promise<void>((resolve) =>
          terminal.write(data, () => {
            host.dataset.writes = String(++writes);
            resolve();
          }),
        );

      const handleFocusIn = () => setFocused(true);
      const handleFocusOut = () => {
        queueMicrotask(() => {
          if (!cancelled) setFocused(host.contains(document.activeElement));
        });
      };
      host.addEventListener("focusin", handleFocusIn);
      host.addEventListener("focusout", handleFocusOut);
      if (focusOnMount) terminal.focus();

      let stream: TerminalStream | null = null;
      let reportedFit: TerminalSize | null = null;
      const applyFit = () => {
        if (cancelled || stream === null) return;
        const next = nextFitSize(reportedFit, fit.proposeDimensions());
        if (!next) return;
        reportedFit = next;
        transport.resize(surface, next.cols, next.rows).catch((error: unknown) => {
          if (reportedFit?.cols === next.cols && reportedFit.rows === next.rows) reportedFit = null;
          fail(error);
        });
      };
      const sendResize = debounce(applyFit, 100);
      const observer = new ResizeObserver(sendResize);
      observer.observe(host);
      const input = terminal.onData((text) => {
        transport.input(surface, text).catch(fail);
      });
      let retryTimer: ReturnType<typeof setTimeout> | undefined;

      dispose = () => {
        observer.disconnect();
        sendResize.cancel();
        input.dispose();
        host.removeEventListener("focusin", handleFocusIn);
        host.removeEventListener("focusout", handleFocusOut);
        if (retryTimer !== undefined) clearTimeout(retryTimer);
        stream?.close();
        stream = null;
        Reflect.deleteProperty(host, "cmuxScreenText");
        delete host.dataset.ready;
        terminal.dispose();
        void transport.release(surface).catch(() => undefined);
        setFocused(false);
      };

      let attempt = 0;
      let stableSince = 0;
      for (;;) {
        stream = await transport.open(surface);
        if (cancelled) return;
        reportedFit = null;
        let overflowed = false;
        for (;;) {
          const event = await stream.next();
          if (cancelled) return;
          if (event.kind === "replay") {
            terminal.reset();
            terminal.resize(event.cols, event.rows);
            await write(event.data);
            if (cancelled) return;
            host.dataset.ready = "true";
            applyFit();
            stableSince = performance.now();
          } else if (event.kind === "output") {
            await write(event.data);
          } else if (event.kind === "overflow") {
            overflowed = true;
            break;
          } else {
            break;
          }
        }
        stream.close();
        stream = null;
        if (!overflowed) return;
        if (performance.now() - stableSince >= ATTACH_RECOVERY_STABLE_MS) attempt = 0;
        const delayMs = attachRecoveryDelay(attempt++);
        if (delayMs === null) throw new Error(t("attachOverflowRecoveryFailed"));
        await new Promise<void>((resolve) => {
          retryTimer = setTimeout(resolve, delayMs);
        });
        if (cancelled) return;
      }
    })().catch(fail);

    return () => {
      cancelled = true;
      dispose?.();
    };
  }, [focusOnMount, host, onError, surface, transport]);

  return { terminalRef, focused };
}
