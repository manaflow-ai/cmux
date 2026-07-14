import { useCallback, useEffect, useState } from "react";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { CmuxTimeoutError } from "cmux/browser";
import type {
  CmuxClient,
  DecodedColorsChangedEvent,
  DecodedOutputEvent,
  DecodedResizedEvent,
  DecodedVtStateEvent,
  Id,
  OverflowEvent,
} from "cmux/browser";
import { ATTACH_RECOVERY_STABLE_MS, attachRecoveryDelay } from "../lib/attachRecovery";
import { debounce } from "../lib/debounce";
import { t } from "../i18n";
import { isForeignSmaller, nextFitSize, type TerminalSize } from "../lib/fit";
import { colorsToCursorOptionsPatch, colorsToThemePatch } from "../lib/terminalColors";
import { terminalTheme } from "../lib/terminalTheme";
import { tryLoadWebglRenderer } from "../lib/webglRenderer";

interface AttachedTerminalOptions {
  client: CmuxClient | null;
  surface: Id | null;
  onError(error: Error): void;
}

export function useAttachedTerminal({ client, surface, onError }: AttachedTerminalOptions) {
  const [host, setHost] = useState<HTMLDivElement | null>(null);
  const [focused, setFocused] = useState(false);
  const [foreignSizeState, setForeignSizeState] = useState<{
    client: CmuxClient;
    surface: Id;
    size: TerminalSize;
  } | null>(null);
  const terminalRef = useCallback((node: HTMLDivElement | null) => setHost(node), []);

  useEffect(() => {
    if (!host || !client || surface === null) return;
    let cancelled = false;
    const baseTheme = terminalTheme(host);
    const stage = host.closest<HTMLElement>(".terminal-stage");
    const terminal = new Terminal({
      allowProposedApi: true,
      convertEol: false,
      disableStdin: true,
      fontFamily: '"SFMono-Regular", Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      lineHeight: 1.15,
      theme: baseTheme,
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.open(host);
    const webgl = tryLoadWebglRenderer(terminal);

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

    // tmux window-size=latest: false after a foreign size is applied, so the
    // next local keystroke claims the surface back to this pane's fit. The
    // flag makes the claim one applyFit per divergence, not one per key.
    let sizeClaimed = true;
    const publishForeignSize = (size: TerminalSize | null) => {
      setForeignSizeState((current) => {
        if (size === null) return current === null ? current : null;
        if (
          current?.client === client
          && current.surface === surface
          && current.size.cols === size.cols
          && current.size.rows === size.rows
        ) return current;
        return { client, surface, size };
      });
    };
    const updateForeignSize = (current: TerminalSize, proposed: TerminalSize | undefined) => {
      publishForeignSize(isForeignSmaller(current, proposed) ? current : null);
    };
    const applyFit = () => {
      if (cancelled) return;
      sizeClaimed = true;
      const current = { cols: terminal.cols, rows: terminal.rows };
      const proposed = fit.proposeDimensions();
      const next = nextFitSize(current, proposed);
      // A local fit is the size claim, including a no-op when the current
      // terminal already matches the pane.
      publishForeignSize(null);
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
    const input = terminal.onData((text) => {
      if (!sizeClaimed) applyFit();
      void client.send(surface, { text }).catch(onError);
    });
    const applyColors = (colors: DecodedVtStateEvent["colors"] | DecodedColorsChangedEvent) => {
      const themePatch = colorsToThemePatch(colors);
      if (themePatch !== null) {
        terminal.options.theme = { ...baseTheme, ...themePatch };
        if (themePatch.background !== undefined) {
          stage?.style.setProperty("--surface-background", themePatch.background);
        } else {
          stage?.style.removeProperty("--surface-background");
        }
      }
      const cursorPatch = colorsToCursorOptionsPatch(colors);
      if (cursorPatch !== null) Object.assign(terminal.options, cursorPatch);
    };
    let stream: Awaited<ReturnType<CmuxClient["attachSurface"]>> | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let stableTimer: ReturnType<typeof setTimeout> | undefined;
    let wakeRetry: (() => void) | null = null;

    const waitForRetry = (delayMs: number) =>
      new Promise<void>((resolve) => {
        wakeRetry = resolve;
        retryTimer = setTimeout(() => {
          retryTimer = undefined;
          wakeRetry = null;
          resolve();
        }, delayMs);
      });

    void (async () => {
      try {
        let recoveryAttempt = 0;
        for (;;) {
          stream = await client.attachSurface(surface);
          // Cleanup may have raced the attach round-trip; close the stream we
          // just opened or its buffered events leak for the surface's lifetime.
          if (cancelled) return;
          let overflowed = false;
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
              terminal.reset();
              applyColors(replay.colors);
              terminal.resize(replay.cols, replay.rows);
              terminal.write(replay.data);
              updateForeignSize({ cols: replay.cols, rows: replay.rows }, fit.proposeDimensions());
              // Attaching is our interaction: fit the replayed surface to this
              // pane and push it (latest-interaction-wins). Foreign `resized`
              // events below are accepted as-is, so clients do not ping-pong sizes.
              applyFit();
              terminal.options.disableStdin = false;
              if (stableTimer !== undefined) clearTimeout(stableTimer);
              stableTimer = setTimeout(() => {
                stableTimer = undefined;
                recoveryAttempt = 0;
              }, ATTACH_RECOVERY_STABLE_MS);
            } else if (event.event === "output") {
              terminal.write((event as DecodedOutputEvent).data);
            } else if (event.event === "resized") {
              const resized = event as DecodedResizedEvent;
              terminal.reset();
              terminal.resize(resized.cols, resized.rows);
              terminal.write(resized.data);
              updateForeignSize({ cols: resized.cols, rows: resized.rows }, fit.proposeDimensions());
              // Could be our own echo; applyFit no-ops in that case.
              sizeClaimed = false;
            } else if (event.event === "colors-changed") {
              applyColors(event as DecodedColorsChangedEvent);
            } else if (event.event === "overflow") {
              const overflow = event as OverflowEvent;
              if (overflow.scope === "surface" && overflow.surface === surface) {
                terminal.options.disableStdin = true;
                if (stableTimer !== undefined) {
                  clearTimeout(stableTimer);
                  stableTimer = undefined;
                }
                overflowed = true;
                break;
              }
            }
          }
          stream.close();
          stream = null;
          if (!overflowed) return;
          const delayMs = attachRecoveryDelay(recoveryAttempt++);
          if (delayMs === null) {
            throw new Error(t("attachOverflowRecoveryFailed"));
          }
          await waitForRetry(delayMs);
          if (cancelled) return;
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
      if (retryTimer !== undefined) clearTimeout(retryTimer);
      if (stableTimer !== undefined) clearTimeout(stableTimer);
      wakeRetry?.();
      stream?.close();
      webgl?.dispose();
      terminal.dispose();
      stage?.style.removeProperty("--surface-background");
      setFocused(false);
      publishForeignSize(null);
    };
  }, [client, host, onError, surface]);

  const foreignSize = host !== null && foreignSizeState?.client === client && foreignSizeState.surface === surface
    ? foreignSizeState.size
    : null;
  return { terminalRef, focused, foreignSize };
}
