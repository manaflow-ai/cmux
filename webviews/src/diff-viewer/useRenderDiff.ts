// Owns rendering a diff session: streaming the patch into items, adopting a replacement
// session, the transport's lifetime, deferred hydration and re-languaging after registry changes.
import { parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import { useEffect, useRef } from "react";
import { resolveDiffViewerAppearance, type ResolvedDiffViewerAppearance } from "../appearance";
import { resolveDiffPreloadLanguages } from "../diff-language";
import { fileName, type DiffItem, streamPatch } from "../diff-stream";
import { DEFERRED_PATCH_KEY, hydrateDeferredFileDiff } from "../deferred-parse";
import { isGeneratedDiffPath } from "../deferred-diffs";
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
import { withoutImportOnlyHunks } from "./importHunks";

const registeredCustomThemeNames = new Set<string>();

/**
 * Registers the terminal theme's Shiki themes under their names. The surface calls it before the
 * viewer's first render, so the highlight pool (created on that render, App.tsx) can start its
 * workers while the patch is still on its way; the stream calls it again for a new render.
 */
export function registerDiffViewerThemes(appearance: ResolvedDiffViewerAppearance): void {
  for (const theme of [appearance.themes.light, appearance.themes.dark]) {
    if (theme.name && !registeredCustomThemeNames.has(theme.name)) {
      registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme, appearance)));
      registeredCustomThemeNames.add(theme.name);
    }
  }
}
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
  /** Hide white space as chosen; App changes it only together with a refresh (setOption). */
  hideWhitespace: boolean,
  /** Hide imports as chosen (importHunks.ts); as `hideWhitespace`, it changes with a refresh. */
  hideImports: boolean,
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
    registerDiffViewerThemes(appearance);
    let cancelled = false;
    const streamAbortController = new AbortController();
    const handlePageHide = () => {
      void closeActiveSession();
    };
    window.addEventListener("pagehide", handlePageHide);
    // An empty diff with white space hidden is not "no changes".
    let hidingWhitespace = false;
    // This run's sessionOpen is in flight. Only then does the cleanup close the pending session:
    // the host cancels whatever open is in flight on that close, and after a refresh (which has
    // closed the active session) that would be the next run's open (CancellationError, "Could not
    // render this diff" on Hide imports and Hide white space).
    let opening = false;
    const emptyMessage = () =>
      hidingWhitespace
        ? label("noChangesWithWhitespaceHidden")
        : hideImports
          ? label("noChangesWithImportsHidden")
          : typeof payload.emptyMessage === "string"
            ? payload.emptyMessage
            : label("noFileDiffs");
    void (async () => {
      try {
        let patchURL = payload.patchURL as string | undefined;
        // Taken once: a later render of the same source opens its own session.
        const adopted = adoptedSessionRef.current;
        adoptedSessionRef.current = null;
        const session = adopted ? null : diffSessionRequest(payload, transport, sessionSource, hideWhitespace);
        hidingWhitespace = session?.ignoreWhitespace === true;
        if (adopted || session) {
          let opened: SessionOpened;
          if (adopted) {
            opened = adopted.session;
          } else {
            opening = true;
            const result = await transport!
              .request({ method: "sessionOpen", params: session! })
              .finally(() => (opening = false));
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
          // Older sidecars omit the field: white space is shown.
          hidingWhitespace = result.value.ignoreWhitespace === true;
          dispatch({ type: "set-whitespace-hidden", hidden: hidingWhitespace });
          patchURL = result.value.patch.id;
        }
        if (cancelled || !patchURL) {
          return;
        }
        onPatchURL(patchURL);
        // The sidecar's generated list as a set, rebuilt only when the list itself changes.
        let declaredPaths: readonly string[] = [];
        let declaredSet: ReadonlySet<string> = new Set<string>();
        const declaredGenerated = (): ReadonlySet<string> => {
          const paths = latestState.current.generatedPaths;
          if (paths !== declaredPaths) {
            declaredPaths = paths;
            declaredSet = new Set(paths);
          }
          return declaredSet;
        };
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
            // Every file has arrived, so "Group by kind" can reorder without moving text the
            // reader is already on.
            dispatch({ type: "set-stream-complete" });
            const items = streamedItems;
            if (items.length === 0) {
              dispatch({
                type: "set-status",
                status: createDiffViewerStatus(emptyMessage(), { error: false, loading: false, statusOnly: true }),
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
          isGeneratedPath: (path) => isGeneratedDiffPath(path, declaredGenerated()),
          ...(hideImports ? { filterFileText: withoutImportOnlyHunks } : {}),
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
        dispatch({
          type: "set-status",
          status: createDiffViewerStatus(empty ? emptyMessage() : label("renderFailed"), {
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
      if (opening || activeSessionRef.current) void closeActiveSession();
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
    hideWhitespace,
    hideImports,
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
  type PendingHydration = { item: DiffItem; timer?: ReturnType<typeof setTimeout> };
  const pending = useRef(new Map<string, PendingHydration>());
  useEffect(() => {
    const scheduled = pending.current;
    for (const item of items) {
      if (item.collapsed || item.fileDiff?.[DEFERRED_PATCH_KEY] == null || scheduled.has(item.id)) {
        continue;
      }
      const entry: PendingHydration = { item };
      scheduled.set(item.id, entry);
      entry.timer = setTimeout(() => {
        if (scheduled.get(item.id) !== entry) return;
        scheduled.delete(item.id);
        const fileDiff = hydrateDeferredFileDiff(item.fileDiff, processFile);
        if (fileDiff != null) {
          resolveDiffItemLanguage({ ...item, fileDiff } as DiffItem);
          // Carry the placeholder identity through the reducer as a second line of defense. React
          // may defer passive effect cleanup until after a zero-delay task, and path-derived ids can
          // be reused by the replacement session in that window.
          dispatch({ type: "hydrate-item", itemId: item.id, fileDiff, expectedFileDiff: item.fileDiff });
        }
      }, 0);
    }
    return () => {
      for (const entry of scheduled.values()) if (entry.timer !== undefined) clearTimeout(entry.timer);
      scheduled.clear();
    };
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
