// Owns rendering a diff session: streaming the patch into items, adopting a replacement
// session, the transport's lifetime, deferred hydration and re-languaging after registry changes.
import { parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import { useEffect, useRef } from "react";
import { resolveDiffViewerAppearance } from "../appearance";
import { resolveDiffPreloadLanguages } from "../diff-language";
import { fileName, type DiffItem, streamPatch } from "../diff-stream";
import { DEFERRED_PATCH_KEY, hydrateDeferredFileDiff } from "../deferred-parse";
import { shikiThemeFromGhostty } from "../pierre-options";
import { createDiffViewerStatus } from "../status";
import type { DiffViewerLabelResolver } from "../labels";
import type { DiffViewerConfig } from "../types";
import { createDiffTransport, DiffTransportError, type DiffTransport } from "../diff/transport";
import type { DiffSource, DiffTransportConfig, SessionOpened } from "../diff/generated/protocol";
import { diffLanguages } from "../diff-languages/registry";
import { resolveDiffItemLanguage } from "./item-languages";
import {
  type ActiveDiffSession,
  type AdoptedDiffSession,
  closeDiffSession,
  diffSessionRequest,
  isStatusOnlyPayload,
} from "./session";
import { type AppAction, type AppState } from "./state";
import { getInitialFileTreeRowCount } from "./FilesSidebar";

const registeredCustomThemeNames = new Set<string>();
/// Re-detects every file's language when the host installs new user languages or overrides.
export function useDiffLanguageChanges(dispatch: React.Dispatch<AppAction>): void {
  useEffect(() => diffLanguages.subscribe(() => dispatch({ type: "relanguage-items" })), [dispatch]);
}

export function useRenderDiff(
  config: DiffViewerConfig,
  transport: DiffTransport | null,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  latestState: React.MutableRefObject<AppState>,
  onPatchURL: (url: string) => void,
  activeSessionRef: React.MutableRefObject<ActiveDiffSession | null>,
  closeActiveSession: () => Promise<void>,
  sessionSource: DiffSource | null,
  onResolvedSessionSource: (source: DiffSource) => void,
  renderGeneration: number,
  adoptedSessionRef: React.MutableRefObject<AdoptedDiffSession | null>,
) {
  useEffect(() => {
    if (isStatusOnlyPayload(config.payload, transport, sessionSource)) {
      return;
    }
    // A soft refresh bumps the generation: the cleanup below closes the
    // superseded session and this effect re-streams in place.
    document.body.dataset.diffRenderGeneration = String(renderGeneration);
    const payload = config.payload ?? {};
    const appearance = resolveDiffViewerAppearance(payload.appearance);
    for (const theme of [appearance.themes.light, appearance.themes.dark]) {
      if (theme.name && !registeredCustomThemeNames.has(theme.name)) {
        registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme, appearance)));
        registeredCustomThemeNames.add(theme.name);
      }
    }
    let cancelled = false;
    const streamAbortController = new AbortController();
    const handlePageHide = () => {
      void closeActiveSession();
    };
    window.addEventListener("pagehide", handlePageHide);
    void (async () => {
      try {
        let patchURL = payload.patchURL as string | undefined;
        // Taken once: a later render of the same source opens its own session.
        const adopted = adoptedSessionRef.current;
        adoptedSessionRef.current = null;
        const session = adopted ? null : diffSessionRequest(payload, transport, sessionSource);
        if (adopted || session) {
          let opened: SessionOpened;
          if (adopted) {
            opened = adopted.session;
          } else {
            const result = await transport!.request({ method: "sessionOpen", params: session! });
            if (result.type !== "sessionOpened") {
              throw new DiffTransportError("invalidResponse", "Diff transport did not open a session");
            }
            opened = result.value;
          }
          const result = { value: opened };
          const openedSession = {
            sessionId: opened.sessionId,
            capabilityToken: adopted?.capabilityToken ?? String(payload.capabilityToken ?? ""),
          };
          if (cancelled) {
            await closeDiffSession(transport!, openedSession);
            return;
          }
          activeSessionRef.current = openedSession;
          onResolvedSessionSource(result.value.source);
          // Older sidecars omit the field; the lockfile heuristic still applies.
          const generatedPaths = Array.isArray(result.value.generatedPaths)
            ? result.value.generatedPaths.filter((path): path is string => typeof path === "string")
            : [];
          dispatch({ type: "set-generated-paths", paths: generatedPaths });
          patchURL = result.value.patch.id;
        }
        if (cancelled || !patchURL) {
          return;
        }
        onPatchURL(patchURL);
        const streamedItems: DiffItem[] = [];
        dispatch({ type: "set-status", status: createDiffViewerStatus(label("parsingDiff"), { loading: true }) });
        await streamPatch({
          getCollapsed: () => latestState.current.options.collapsed,
          initialFileTreeRowCount: getInitialFileTreeRowCount(),
          label,
          signal: streamAbortController.signal,
          onBatch: (items) => {
            if (cancelled) return;
            streamedItems.push(...items);
            dispatch({ type: "append-items", items });
          },
          onComplete: (metrics) => {
            if (cancelled) return;
            dispatch({ type: "set-metrics", metrics });
            const items = streamedItems;
            if (items.length === 0) {
              const emptyMessage =
                typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
              dispatch({
                type: "set-status",
                status: createDiffViewerStatus(emptyMessage, { error: false, loading: false, statusOnly: true }),
              });
              return;
            }
            const themes = Array.from(new Set([appearance.theme?.light, appearance.theme?.dark].filter(Boolean)));
            const langs = Array.from(
              new Set(
                items.flatMap((item) => {
                  const diff = item.fileDiff ?? {};
                  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff);
                }),
              ),
            );
            preloadHighlighter({ themes, langs: langs.length > 0 ? langs : ["text"] }).catch((error) =>
              console.warn("cmux diff highlighter preload failed", error),
            );
          },
          onMetrics: (metrics) => {
            if (!cancelled) dispatch({ type: "set-metrics", metrics });
          },
          onRename: (rename) => {
            if (!cancelled) dispatch({ type: "rename-item", oldId: rename.oldId, newId: rename.newId });
          },
          onTreeSource: (source) => {
            if (!cancelled) dispatch({ type: "set-tree-source", source });
          },
          isGeneratedPath: (path) => latestState.current.generatedPaths.includes(path),
          parsePatchFiles,
          patchURL,
          processFile,
        });
      } catch (error) {
        if (cancelled) {
          return;
        }
        const empty = error instanceof DiffTransportError && error.code === "emptyDiff";
        if (!empty) {
          // Error objects JSON.stringify to {} in the native console mirror,
          // so serialize the message and stack explicitly.
          console.error(
            "cmux diff viewer render failed",
            String((error as any)?.stack ?? (error as any)?.message ?? error),
          );
        }
        const emptyMessage = typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
        dispatch({
          type: "set-status",
          status: createDiffViewerStatus(empty ? emptyMessage : label("renderFailed"), {
            error: !empty,
            loading: false,
            statusOnly: true,
          }),
        });
      }
    })();
    return () => {
      cancelled = true;
      streamAbortController.abort();
      window.removeEventListener("pagehide", handlePageHide);
      void closeActiveSession();
    };
  }, [
    activeSessionRef,
    closeActiveSession,
    config,
    dispatch,
    label,
    latestState,
    onPatchURL,
    onResolvedSessionSource,
    renderGeneration,
    sessionSource,
    transport,
    adoptedSessionRef,
  ]);
}

export function usePendingReplacement(
  payload: any,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  transport: DiffTransport | null,
) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    if (payload.pendingReplacement === true) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage ?? label("loadingDiff"), { loading: true, pending: true }),
      });
      if (diffSessionRequest(payload, transport)) {
        return;
      }
      // The native host replaces the file and navigates this surface when Git
      // generation completes. Custom-scheme resources never use an HTTP wait
      // endpoint, so keep the loading state until that navigation arrives.
      if (window.location.protocol === "cmux-diff-viewer:") {
        return;
      }
      fetch("/__cmux_diff_viewer_wait" + window.location.pathname, { cache: "no-store" })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error("replacement failed");
          }
          const text = await response.text();
          if (!text.includes('data-cmux-diff-pending="true"')) {
            window.location.reload();
          }
        })
        .catch((error) => {
          document.documentElement.dataset.cmuxDiffWait = "failed";
          dispatch({
            type: "set-status",
            status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }),
          });
          console.warn("cmux diff viewer deferred load failed", error);
        });
      return;
    }
    if (typeof payload.statusMessage === "string" && payload.statusMessage.length > 0) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage, {
          error: payload.statusIsError === true,
          loading: false,
          statusOnly: true,
        }),
      });
    }
  }, [dispatch, label, payload, transport]);
}

/**
 * Parses a deferred file (deferred-parse.ts) once it is expanded, by Load
 * diff, its header bar, the files tree or find. The parse runs in a task
 * after the expanding commit, so the click's own frame stays short, and its
 * result replaces the placeholder in place.
 */
export function useDeferredHydration(items: DiffItem[], dispatch: React.Dispatch<AppAction>) {
  const scheduled = useRef(new Set<string>());
  useEffect(() => {
    for (const item of items) {
      if (item.collapsed || item.fileDiff?.[DEFERRED_PATCH_KEY] == null || scheduled.current.has(item.id)) {
        continue;
      }
      scheduled.current.add(item.id);
      const placeholder = item.fileDiff;
      setTimeout(() => {
        scheduled.current.delete(item.id);
        const fileDiff = hydrateDeferredFileDiff(placeholder, processFile);
        if (fileDiff != null) {
          resolveDiffItemLanguage({ ...item, fileDiff } as DiffItem);
          dispatch({ type: "hydrate-item", itemId: item.id, fileDiff });
        }
      }, 0);
    }
  }, [dispatch, items]);
}

export function useDiffTransport(config: DiffTransportConfig | undefined): DiffTransport | null {
  const transportRef = useRef<DiffTransport | null | undefined>(undefined);
  if (transportRef.current === undefined) {
    transportRef.current = createDiffTransport(config);
  }
  useEffect(() => {
    const transport = transportRef.current;
    return () => transport?.close();
  }, []);
  return transportRef.current;
}
