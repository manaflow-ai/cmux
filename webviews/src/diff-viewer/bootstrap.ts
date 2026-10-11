// Owns loading the viewer's persisted state at start: display prefs and the Viewed marks of the
// current scope.
import { useEffect, useRef } from "react";
import { type ViewedScope, loadViewedFiles, viewedScopeKey } from "../viewed-files";
import { loadViewerPrefs } from "../viewer-prefs";
import { type AppAction } from "./state";

export function useViewerPrefsBootstrap(payload: any, dispatch: React.Dispatch<AppAction>) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    loadViewerPrefs()
      .then((prefs) => {
        dispatch({
          type: "apply-persisted-options",
          prefs,
          allowLayout: payload.layoutSource !== "explicit",
        });
      })
      .catch(() => {
        // Preferences are a convenience; boot continues with payload defaults.
      });
  }, [dispatch, payload]);
}

/**
 * Loads the persisted "Viewed" marks whenever the reviewed change's identity
 * (repo + source) changes. Cleanup invalidates an older load so a slow reply
 * cannot overwrite marks after a source switch; an unknown scope clears them.
 */
export function useViewedFilesBootstrap(scope: ViewedScope | null, dispatch: React.Dispatch<AppAction>): void {
  const scopeKey = viewedScopeKey(scope);
  useEffect(() => {
    const currentScope = scope;
    // Clear the previous scope's marks before the new diff streams in, so no
    // file of the new source collapses on a mark that belongs to the old one.
    dispatch({ type: "begin-viewed-load", scopeKey });
    if (currentScope == null || scopeKey === "") {
      return;
    }
    let active = true;
    loadViewedFiles(currentScope)
      .then((entries) => {
        if (active) {
          dispatch({ type: "replace-viewed", scopeKey, entries });
        }
      })
      .catch((error) => {
        if (active) {
          console.warn("cmux diff viewed state load failed", error);
        }
      });
    return () => {
      active = false;
    };
    // `scope` is a fresh object per render; `scopeKey` is its identity.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dispatch, scopeKey]);
}
