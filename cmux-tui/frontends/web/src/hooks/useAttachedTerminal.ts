import { useCallback, useEffect, useState } from "react";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { CmuxTimeoutError } from "cmux/browser";
import type {
  CmuxClient,
  DecodedOutputEvent,
  DecodedResizedEvent,
  DecodedVtStateEvent,
  Id,
} from "cmux/browser";
import { debounce } from "../lib/debounce";
import { nextFitSize } from "../lib/fit";
import { terminalTheme } from "../lib/terminalTheme";

interface AttachedTerminalOptions {
  client: CmuxClient | null;
  surface: Id | null;
  onError(error: Error): void;
}

export function useAttachedTerminal({ client, surface, onError }: AttachedTerminalOptions) {
  const [host, setHost] = useState<HTMLDivElement | null>(null);
  const [focused, setFocused] = useState(false);
  const terminalRef = useCallback((node: HTMLDivElement | null) => setHost(node), []);

  useEffect(() => {
    if (!host || !client || surface === null) return;
    let cancelled = false;
    const terminal = new Terminal({
      allowProposedApi: true,
      cursorBlink: true,
      convertEol: false,
      fontFamily: '"SFMono-Regular", Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      lineHeight: 1.15,
      theme: terminalTheme(host),
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.open(host);

    const handleFocusIn = () => setFocused(true);
    const handleFocusOut = () => {
      queueMicrotask(() => {
        if (!cancelled) setFocused(host.contains(document.activeElement));
      });
    };
    const focusOnTouch = () => terminal.focus();
    host.addEventListener("focusin", handleFocusIn);
    host.addEventListener("focusout", handleFocusOut);
    host.addEventListener("touchend", focusOnTouch, { passive: true });

    const applyFit = () => {
      if (cancelled) return;
      const next = nextFitSize({ cols: terminal.cols, rows: terminal.rows }, fit.proposeDimensions());
      if (!next) return;
      terminal.resize(next.cols, next.rows);
      void client.resizeSurface(surface, next.cols, next.rows).catch(onError);
    };
    const sendResize = debounce(applyFit, 100);
    const observer = new ResizeObserver(sendResize);
    observer.observe(host);
    window.visualViewport?.addEventListener("resize", sendResize);
    window.visualViewport?.addEventListener("scroll", sendResize);
    sendResize();
    const input = terminal.onData((text) => void client.send(surface, { text }).catch(onError));
    let stream: Awaited<ReturnType<CmuxClient["attachSurface"]>> | null = null;

    void (async () => {
      try {
        stream = await client.attachSurface(surface);
        // Cleanup may have raced the attach round-trip; close the stream we
        // just opened or its buffered events leak for the surface's lifetime.
        if (cancelled) return;
        for (;;) {
          let event;
          try {
            event = await stream.next();
          } catch (error) {
            if (cancelled) return;
            // Idle terminals produce no output within the SDK's per-read
            // timeout; keep reading. Anything else ends the attachment.
            if (error instanceof CmuxTimeoutError) continue;
            throw error;
          }
          if (cancelled) return;
          if (event.event === "vt-state") {
            const replay = event as DecodedVtStateEvent;
            terminal.resize(replay.cols, replay.rows);
            terminal.write(replay.data);
            // Attaching is our interaction: fit the replayed surface to this
            // pane and push it (latest-interaction-wins). Foreign `resized`
            // events below are accepted as-is — the pane clips them — so the
            // two attached clients never ping-pong sizes.
            applyFit();
          } else if (event.event === "output") {
            terminal.write((event as DecodedOutputEvent).data);
          } else if (event.event === "resized") {
            const resized = event as DecodedResizedEvent;
            terminal.reset();
            terminal.resize(resized.cols, resized.rows);
            terminal.write(resized.data);
          }
        }
      } catch (error) {
        if (!cancelled) onError(error instanceof Error ? error : new Error(String(error)));
      } finally {
        stream?.close();
      }
    })();

    return () => {
      cancelled = true;
      observer.disconnect();
      window.visualViewport?.removeEventListener("resize", sendResize);
      window.visualViewport?.removeEventListener("scroll", sendResize);
      host.removeEventListener("focusin", handleFocusIn);
      host.removeEventListener("focusout", handleFocusOut);
      host.removeEventListener("touchend", focusOnTouch);
      sendResize.cancel();
      input.dispose();
      stream?.close();
      terminal.dispose();
      setFocused(false);
    };
  }, [client, host, onError, surface]);

  return { terminalRef, focused };
}
