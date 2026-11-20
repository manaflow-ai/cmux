// Pierre's `File` painted into a host element in the pane's worker pool, with the pane's syntax theme:
// what the fenced card (HighlightedCode.tsx) and a read's bare lines (HighlightedLines.tsx) share.
import { useId, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { MAX_TOKENIZED_LINE } from "./highlightLimits";
import { onHighlightTimeout, paneHighlightPool } from "./highlightPool";
import { highlightWorkerFailed, subscribeHighlightWorker } from "./highlightWorkerState";

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

/// Pierre's `File` in the pane's syntax theme, painted into `host` in the pane's worker pool: what the
/// fenced card and a read's bare lines (HighlightedLines.tsx) share. `painted` turns true once its lines
/// are on screen; `workerAvailable` false (no pool, a failed worker, a job past its budget) means the
/// caller draws plain lines instead.
export function usePierreCode(code: string, lang: string, unsafeCSS: string, wrap: boolean) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const pool = paneHighlightPool("word-alt", isHighlighted(lang) ? lang : "text");
  const workerFailed = useSyncExternalStore(subscribeHighlightWorker, highlightWorkerFailed, () => false);
  const [painted, setPainted] = useState(false);
  // A highlight job past its budget (highlightWatchdog.ts) draws the card as plain text.
  const name = `snippet-${useId()}`;
  const [tooSlow, setTooSlow] = useState(false);
  const workerAvailable = Boolean(pool?.isWorkingPool()) && !workerFailed && !tooSlow;
  useLayoutEffect(() => onHighlightTimeout(name, () => setTooSlow(true)), [name]);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    setPainted(false);
    registerAgentDiffTheme();
    const file = new PierreFile(
      {
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
        themeType: paneThemeType(),
        disableFileHeader: true,
        disableLineNumbers: true,
        overflow: "scroll",
        unsafeCSS,
        tokenizeMaxLineLength: MAX_TOKENIZED_LINE,
        onPostRender: (node, _instance, phase) => {
          if (phase !== "unmount" && node.shadowRoot?.querySelector("[data-line]")) setPainted(true);
        },
      },
      pool,
      // React owns the host element: Pierre must not remove it on cleanUp.
      true,
    );
    view.current = file;
    const theme = new MutationObserver(() => file.setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      theme.disconnect();
      view.current = undefined;
      file.cleanUp();
      el.shadowRoot?.replaceChildren();
    };
  }, [lang, unsafeCSS, pool, workerAvailable]);
  useLayoutEffect(() => {
    const el = host.current;
    const file = view.current;
    if (!el || !file || !workerAvailable || highlightWorkerFailed() || !pool?.isWorkingPool()) return;
    file.setOptions({ ...file.options, overflow: wrap ? "wrap" : "scroll" });
    // Shiki throws for a language the bundle does not ship; those draw as plain text.
    file.render({
      fileContainer: el,
      file: { name, contents: code, lang: (isHighlighted(lang) ? lang : "text") as never },
    });
  }, [code, lang, unsafeCSS, pool, wrap, name, workerAvailable]);
  return { host, painted, workerAvailable };
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
export const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
