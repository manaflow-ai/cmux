import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import {
  CmuxTimeoutError,
  type CmuxClient,
  type CmuxStream,
  type Id,
  type RenderAttachEvent,
  type RenderDeltaEvent,
  type RenderRow,
  type RenderStateEvent,
} from "cmux/browser";
import { ATTACH_RECOVERY_STABLE_MS, attachRecoveryDelay } from "../lib/attachRecovery";
import { debounce } from "../lib/debounce";
import { t } from "../i18n";
import { syncCanvasBackground } from "../lib/canvasTheme";
import { nextFitSize, type TerminalSize } from "../lib/fit";
import { createFrameBatch } from "../lib/frameBatch";
import { encodeTerminalKey } from "../lib/keyEncoding";
import { beginTerminalSelection, clampTerminalSelection, releaseTerminalSelection } from "../lib/terminalSelection";
import { applyDelta, applySnapshot, type RenderModel } from "../lib/renderModel";
import {
  createScrollbackWindow,
  latestScrollbackRequest,
  mergeScrollbackPage,
  nextScrollbackRequest,
  previousScrollbackRequest,
  reconcileScrollbackWindow,
  scrollbackAnchorDelta,
  type ScrollbackWindow,
} from "../lib/scrollback";

interface RenderTerminalOptions {
  client: CmuxClient | null;
  surface: Id | null;
  active: boolean;
  focusOnMount?: boolean;
  onError(error: Error): void;
}

interface RenderHistoryView {
  active: boolean;
  loading: boolean;
  total: number;
  rows: readonly RenderRow[];
}

interface RenderTerminalViewState {
  client: CmuxClient | null;
  surface: Id | null;
  model: RenderModel | null;
  focused: boolean;
  history: RenderHistoryView;
}

type RenderTerminalViewAction =
  | { type: "bind"; client: CmuxClient; surface: Id }
  | { type: "reset"; client: CmuxClient; surface: Id }
  | {
    type: "frame";
    client: CmuxClient;
    surface: Id;
    model: RenderModel;
    history: RenderHistoryView;
  }
  | { type: "focus"; client: CmuxClient; surface: Id; focused: boolean }
  | { type: "history"; client: CmuxClient; surface: Id; history: RenderHistoryView };

const emptyHistory: RenderHistoryView = { active: false, loading: false, total: 0, rows: [] };
const initialState: RenderTerminalViewState = {
  client: null,
  surface: null,
  model: null,
  focused: false,
  history: emptyHistory,
};

function renderTerminalViewReducer(
  state: RenderTerminalViewState,
  action: RenderTerminalViewAction,
): RenderTerminalViewState {
  if (action.type === "bind") {
    return { ...initialState, client: action.client, surface: action.surface };
  }
  if (state.client !== action.client || state.surface !== action.surface) return state;
  switch (action.type) {
    case "reset":
      return initialState;
    case "frame":
      return {
        ...state,
        model: action.model,
        history: action.history,
      };
    case "focus":
      return { ...state, focused: action.focused };
    case "history":
      return { ...state, history: action.history };
  }
}

interface RenderTerminalController {
  backToLive(): void;
  sendKey(key: string): void;
  sendText(text: string, paste?: boolean): void;
}

export function useRenderTerminal({
  client,
  surface,
  active,
  focusOnMount = false,
  onError,
}: RenderTerminalOptions) {
  const [host, setHost] = useState<HTMLDivElement | null>(null);
  const [state, dispatch] = useReducer(renderTerminalViewReducer, initialState);
  const controllerRef = useRef<RenderTerminalController | null>(null);
  const activeRef = useRef(active);
  activeRef.current = active;
  const terminalRef = useCallback((node: HTMLDivElement | null) => setHost(node), []);

  useEffect(() => {
    const stage = host?.closest<HTMLElement>(".terminal-stage");
    const background = state.model?.defaultBg ?? stage?.style.getPropertyValue("--surface-background");
    if (!host || !background) return;
    syncCanvasBackground(host, background, active);
  }, [active, host, state.model?.defaultBg]);

  useEffect(() => {
    if (!host || !client || surface === null) return;
    let cancelled = false;
    let stream: CmuxStream<RenderAttachEvent> | null = null;
    let currentModel: RenderModel | null = null;
    let cache: ScrollbackWindow = createScrollbackWindow(0);
    let cacheGeneration = 0;
    let historyActive = false;
    let historyLoading = false;
    let reportedFit: TerminalSize | null = null;
    let composing = false;
    let committedComposition: string | null = null;
    let touchStartY: number | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let stableTimer: ReturnType<typeof setTimeout> | undefined;
    let wakeRetry: (() => void) | null = null;
    const frames = new Set<number>();
    const stage = host.closest<HTMLElement>(".terminal-stage");
    const scroller = host.querySelector<HTMLElement>("[data-render-scroll]");
    const textarea = host.querySelector<HTMLTextAreaElement>("[data-render-input]");
    const probe = host.querySelector<HTMLElement>("[data-render-probe]");
    const metrics = { width: 0, height: 0 };
    const applySurfaceBackground = (background: string) => {
      stage?.style.setProperty("--surface-background", background);
      syncCanvasBackground(host, background, activeRef.current);
    };
    const waitForRetry = (delayMs: number) =>
      new Promise<void>((resolve) => {
        wakeRetry = resolve;
        retryTimer = setTimeout(() => {
          retryTimer = undefined;
          wakeRetry = null;
          resolve();
        }, delayMs);
      });

    dispatch({ type: "bind", client, surface });
    const frameBatch = createFrameBatch<void>(() => {
      if (currentModel === null) return;
      dispatch({
        type: "frame",
        client,
        surface,
        model: currentModel,
        history: historyView(),
      });
    });

    const scheduleAfterRender = (work: () => void) => {
      const frame = requestAnimationFrame(() => {
        frames.delete(frame);
        if (!cancelled) work();
      });
      frames.add(frame);
    };
    const historyView = (): RenderHistoryView => ({
      active: historyActive,
      loading: historyLoading,
      total: cache.total,
      rows: cache.rows,
    });
    const publishHistory = () => {
      dispatch({
        type: "history",
        client,
        surface,
        history: historyView(),
      });
    };
    const scheduleFrame = () => {
      frameBatch.schedule();
    };
    const proposedSize = (): TerminalSize | undefined => {
      if (metrics.width <= 0 || metrics.height <= 0) return undefined;
      const cols = Math.floor(host.clientWidth / metrics.width);
      const rows = Math.floor(host.clientHeight / metrics.height);
      return cols >= 2 && rows >= 1 ? { cols, rows } : undefined;
    };
    const applyFit = () => {
      if (cancelled || stream === null || currentModel === null) return;
      const next = nextFitSize(reportedFit, proposedSize());
      if (next === null) return;
      reportedFit = next;
      void client.resizeSurface(surface, next.cols, next.rows).catch((error) => {
        if (reportedFit?.cols === next.cols && reportedFit.rows === next.rows) reportedFit = null;
        onError(error);
      });
    };
    const sendResize = debounce(() => {
      measureCells();
      applyFit();
    }, 100);
    const measureCells = () => {
      const bounds = probe?.getBoundingClientRect();
      const computed = probe === null ? null : getComputedStyle(probe);
      const fontSize = Number.parseFloat(computed?.fontSize ?? "13") || 13;
      metrics.width = bounds !== undefined && bounds.width > 0 ? bounds.width : fontSize * 0.602;
      metrics.height = bounds !== undefined && bounds.height > 0 ? bounds.height : fontSize * 1.15;
      host.style.setProperty("--render-cell-width", `${metrics.width}px`);
      host.style.setProperty("--render-cell-height", `${metrics.height}px`);
    };
    const returnToLive = () => {
      if (!historyActive) return;
      historyActive = false;
      publishHistory();
      scheduleAfterRender(() => {
        if (scroller !== null) scroller.scrollTop = scroller.scrollHeight;
      });
    };
    const prepareInput = () => {
      returnToLive();
    };
    const sendText = (text: string, paste = false) => {
      if (text.length === 0) return;
      prepareInput();
      void client.send(surface, { text, ...(paste ? { paste: true } : {}) }).catch(onError);
    };
    const sendNamedKey = (key: string) => {
      prepareInput();
      void client.sendKey(surface, [key]).catch(onError);
    };
    const resetHistoryCache = (total: number, publish = true) => {
      cacheGeneration += 1;
      historyLoading = false;
      cache = createScrollbackWindow(total);
      if (publish) publishHistory();
    };
    const loadHistoryPage = async (
      direction: "latest" | "previous" | "next",
      publishLoading = true,
    ) => {
      if (cancelled || historyLoading) return;
      const request = direction === "latest"
        ? latestScrollbackRequest(cache)
        : direction === "previous"
          ? previousScrollbackRequest(cache)
          : nextScrollbackRequest(cache);
      if (request === null) return;
      const generation = cacheGeneration;
      const requestTotal = cache.total;
      historyLoading = true;
      if (publishLoading) publishHistory();
      try {
        const page = await client.readScrollback(surface, request.start, request.count);
        if (cancelled || generation !== cacheGeneration) return;
        const stablePage = page.total < cache.total && cache.total > requestTotal
          ? { ...page, total: cache.total }
          : page;
        const previousCache = cache;
        const anchorScrollTop = scroller?.scrollTop ?? 0;
        const nextCache = mergeScrollbackPage(previousCache, stablePage);
        const anchorDelta = direction === "latest"
          ? 0
          : scrollbackAnchorDelta(previousCache, nextCache, direction);
        cache = nextCache;
        publishHistory();
        scheduleAfterRender(() => {
          if (scroller === null) return;
          if (direction === "latest") {
            scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight - metrics.height);
          } else {
            scroller.scrollTop = Math.max(0, anchorScrollTop + anchorDelta * metrics.height);
          }
        });
      } catch (error) {
        if (!cancelled && generation === cacheGeneration) {
          onError(error instanceof Error ? error : new Error(String(error)));
        }
      } finally {
        if (!cancelled && generation === cacheGeneration) {
          historyLoading = false;
          publishHistory();
        }
      }
    };
    const enterHistory = () => {
      if (historyActive || (currentModel?.scrollbackRows ?? 0) === 0) return;
      const reachesLatest = cache.rows.at(-1)?.row === cache.total - 1;
      if (!reachesLatest) resetHistoryCache(currentModel!.scrollbackRows);
      historyActive = true;
      publishHistory();
      if (cache.rows.length === 0) {
        void loadHistoryPage("latest");
      } else {
        scheduleAfterRender(() => {
          if (scroller !== null) {
            scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight - metrics.height);
          }
        });
      }
    };

    const controller: RenderTerminalController = { backToLive: returnToLive, sendKey: sendNamedKey, sendText };
    controllerRef.current = controller;
    measureCells();

    const observer = new ResizeObserver(sendResize);
    observer.observe(host);
    window.visualViewport?.addEventListener("resize", sendResize);
    window.visualViewport?.addEventListener("scroll", sendResize);
    void document.fonts?.ready.then(() => {
      if (!cancelled) sendResize();
    });

    const handleFocus = () => dispatch({ type: "focus", client, surface, focused: true });
    const handleBlur = () => {
      queueMicrotask(() => {
        if (!cancelled) {
          dispatch({ type: "focus", client, surface, focused: host.contains(document.activeElement) });
        }
      });
    };
    const focusInput = (event: PointerEvent) => {
      if ((event.target as HTMLElement).closest("button")) return;
      const selection = window.getSelection();
      if (selection !== null && !selection.isCollapsed) return;
      textarea?.focus({ preventScroll: true });
    };
    const handleSelectionStart = (event: PointerEvent) => {
      if (event.pointerType === "mouse" && event.button !== 0) return;
      beginTerminalSelection(host);
    };
    const handleSelectionChange = () => clampTerminalSelection(host);
    const handleKeyDown = (event: KeyboardEvent) => {
      const selection = window.getSelection();
      const hasSelection = selection !== null && !selection.isCollapsed;
      const lowerKey = event.key.toLowerCase();
      if (hasSelection && lowerKey === "c" && (event.metaKey || (event.ctrlKey && event.shiftKey))) return;
      if (lowerKey === "v" && (event.metaKey || (event.ctrlKey && event.shiftKey))) return;
      const action = encodeTerminalKey(event);
      if (action === null) return;
      event.preventDefault();
      if (action.kind === "text") sendText(action.text);
      else sendNamedKey(action.key);
      if (textarea !== null) textarea.value = "";
    };
    const handleCompositionStart = () => {
      composing = true;
      committedComposition = null;
    };
    const handleCompositionEnd = (event: CompositionEvent) => {
      composing = false;
      committedComposition = event.data;
      sendText(event.data);
      if (textarea !== null) textarea.value = "";
    };
    const handleInput = () => {
      if (textarea === null || composing) return;
      const text = textarea.value;
      textarea.value = "";
      if (text.length === 0) return;
      if (committedComposition === text) {
        committedComposition = null;
        return;
      }
      committedComposition = null;
      sendText(text);
    };
    const handlePaste = (event: ClipboardEvent) => {
      const text = event.clipboardData?.getData("text/plain") ?? "";
      if (text.length === 0) return;
      event.preventDefault();
      sendText(text, true);
      if (textarea !== null) textarea.value = "";
    };
    const handleWheel = (event: WheelEvent) => {
      if (historyActive) {
        const bottomDistance = scroller === null
          ? Number.POSITIVE_INFINITY
          : scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
        if (event.deltaY > 0 && bottomDistance <= metrics.height * 2 && nextScrollbackRequest(cache) !== null) {
          event.preventDefault();
          void loadHistoryPage("next");
        }
        return;
      }
      if (event.deltaY >= 0) return;
      enterHistory();
      if (historyActive) event.preventDefault();
    };
    const handleTouchStart = (event: TouchEvent) => {
      touchStartY = event.touches[0]?.clientY ?? null;
    };
    const handleTouchMove = (event: TouchEvent) => {
      const y = event.touches[0]?.clientY;
      if (touchStartY === null || y === undefined) return;
      if (!historyActive && y - touchStartY > 8) enterHistory();
      if (historyActive && touchStartY - y > 8) {
        const bottomDistance = scroller === null
          ? Number.POSITIVE_INFINITY
          : scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
        if (bottomDistance <= metrics.height * 2) void loadHistoryPage("next");
      }
    };
    const handleScroll = () => {
      if (!historyActive || historyLoading || scroller === null) return;
      if (scroller.scrollTop <= metrics.height * 2 && previousScrollbackRequest(cache) !== null) {
        void loadHistoryPage("previous");
      } else if (
        scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop <= metrics.height * 2
        && nextScrollbackRequest(cache) !== null
      ) {
        void loadHistoryPage("next");
      }
    };

    textarea?.addEventListener("focus", handleFocus);
    textarea?.addEventListener("blur", handleBlur);
    textarea?.addEventListener("keydown", handleKeyDown);
    textarea?.addEventListener("compositionstart", handleCompositionStart);
    textarea?.addEventListener("compositionend", handleCompositionEnd);
    textarea?.addEventListener("input", handleInput);
    textarea?.addEventListener("paste", handlePaste);
    host.addEventListener("pointerdown", handleSelectionStart);
    host.addEventListener("pointerup", focusInput);
    host.addEventListener("wheel", handleWheel, { passive: false });
    host.addEventListener("touchstart", handleTouchStart, { passive: true });
    host.addEventListener("touchmove", handleTouchMove, { passive: true });
    scroller?.addEventListener("scroll", handleScroll, { passive: true });
    document.addEventListener("selectionchange", handleSelectionChange);
    if (focusOnMount && textarea !== null) {
      textarea.focus({ preventScroll: true });
      handleFocus();
    }

    void (async () => {
      try {
        let recoveryAttempt = 0;
        for (;;) {
          stream = await client.attachSurface(surface, { mode: "render" });
          if (cancelled) return;
          // Closing the previous attachment removes this client's report on
          // the server. Re-publish even when the viewport did not change.
          reportedFit = null;
          let overflowed = false;
          for (;;) {
            let event: RenderAttachEvent;
            try {
              event = await stream.next();
            } catch (error) {
              if (cancelled) return;
              if (error instanceof CmuxTimeoutError) continue;
              throw error;
            }
            if (cancelled) return;
            if (event.event === "detached") return;
            if (event.event === "render-state") {
              currentModel = applySnapshot(event as RenderStateEvent);
              resetHistoryCache(currentModel.scrollbackRows, false);
              applySurfaceBackground(currentModel.defaultBg);
              applyFit();
              scheduleFrame();
              if (stableTimer !== undefined) clearTimeout(stableTimer);
              stableTimer = setTimeout(() => {
                stableTimer = undefined;
                recoveryAttempt = 0;
              }, ATTACH_RECOVERY_STABLE_MS);
            } else if (event.event === "render-delta" && currentModel !== null) {
              const renderDelta = event as RenderDeltaEvent;
              const previous: RenderModel = currentModel;
              const nextModel: RenderModel = applyDelta(previous, renderDelta);
              currentModel = nextModel;
              if (nextModel === previous) continue;
              const reconciliation = reconcileScrollbackWindow(
                cache,
                previous.scrollbackRows,
                nextModel.scrollbackRows,
                renderDelta.size !== undefined,
              );
              if (reconciliation.invalidated) {
                cacheGeneration += 1;
                historyLoading = false;
                cache = reconciliation.window;
                if (historyActive) void loadHistoryPage("latest", false);
              } else if (reconciliation.window !== cache) {
                cache = reconciliation.window;
              }
              applySurfaceBackground(nextModel.defaultBg);
              if (!historyActive) {
                scheduleAfterRender(() => {
                  if (scroller !== null) scroller.scrollTop = scroller.scrollHeight;
                });
              }
              scheduleFrame();
            } else if (event.event === "overflow") {
              if (event.scope === "surface" && event.surface === surface) {
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
          if (delayMs === null) throw new Error(t("attachOverflowRecoveryFailed"));
          await waitForRetry(delayMs);
          if (cancelled) return;
        }
      } catch (error) {
        if (!cancelled) onError(error instanceof Error ? error : new Error(String(error)));
      } finally {
        stream?.close();
        if (!cancelled) {
          reportedFit = null;
          try {
            await client.releaseSurfaceSize(surface);
          } catch (error) {
            onError(error instanceof Error ? error : new Error(String(error)));
          }
        }
      }
    })();

    sendResize();
    return () => {
      cancelled = true;
      observer.disconnect();
      window.visualViewport?.removeEventListener("resize", sendResize);
      window.visualViewport?.removeEventListener("scroll", sendResize);
      sendResize.cancel();
      if (retryTimer !== undefined) clearTimeout(retryTimer);
      if (stableTimer !== undefined) clearTimeout(stableTimer);
      wakeRetry?.();
      textarea?.removeEventListener("focus", handleFocus);
      textarea?.removeEventListener("blur", handleBlur);
      textarea?.removeEventListener("keydown", handleKeyDown);
      textarea?.removeEventListener("compositionstart", handleCompositionStart);
      textarea?.removeEventListener("compositionend", handleCompositionEnd);
      textarea?.removeEventListener("input", handleInput);
      textarea?.removeEventListener("paste", handlePaste);
      host.removeEventListener("pointerdown", handleSelectionStart);
      host.removeEventListener("pointerup", focusInput);
      host.removeEventListener("wheel", handleWheel);
      host.removeEventListener("touchstart", handleTouchStart);
      host.removeEventListener("touchmove", handleTouchMove);
      scroller?.removeEventListener("scroll", handleScroll);
      document.removeEventListener("selectionchange", handleSelectionChange);
      for (const frame of frames) cancelAnimationFrame(frame);
      frames.clear();
      frameBatch.cancel();
      stream?.close();
      reportedFit = null;
      void client.releaseSurfaceSize(surface).catch(onError);
      stage?.style.removeProperty("--surface-background");
      releaseTerminalSelection(host);
      if (controllerRef.current === controller) controllerRef.current = null;
      dispatch({ type: "reset", client, surface });
    };
  }, [client, focusOnMount, host, onError, surface]);

  const backToLive = useCallback(() => controllerRef.current?.backToLive(), []);
  const sendKey = useCallback((key: string) => controllerRef.current?.sendKey(key), []);
  const sendText = useCallback((text: string) => controllerRef.current?.sendText(text), []);
  const bound = host !== null && state.client === client && state.surface === surface;
  return {
    terminalRef,
    focused: bound && state.focused,
    model: bound ? state.model : null,
    history: bound ? state.history : emptyHistory,
    backToLive,
    sendKey,
    sendText,
  };
}
