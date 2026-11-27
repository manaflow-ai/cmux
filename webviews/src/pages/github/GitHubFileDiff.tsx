// One changed file's diff drawn inline under its row (Leo, 2026-11-07: "we can expand some of these
// inline ... we can still keep them default collapsed"), on @pierre/diffs, the diff viewer's own
// renderer. GitHubPage.tsx loads this chunk only when a file first opens, so the page's first
// script parses without Pierre. The page ships no highlight worker, so the lines are drawn plain
// (added and removed tints, no syntax colours) rather than tokenized on the page's main thread;
// the full diff viewer, one click away, has them.
import { useEffect, useMemo, useState } from "react";
import { getSingularPatch, setLanguageOverride } from "@pierre/diffs";
import { FileDiff } from "@pierre/diffs/react";
import {
  AGENT_DIFF_THEME,
  AGENT_DIFF_THEME_LIGHT,
  diffUnsafeCSS,
  registerAgentDiffTheme,
} from "../../agent-session/acpmux/diffTheme";

/// The page's theme: the host's `data-theme`, else the system's.
function pageThemeType(): "light" | "dark" {
  const theme = document.documentElement.dataset.theme;
  if (theme === "light" || theme === "dark") return theme;
  return typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

/// Pierre paints its host in the page colour; here it is clear, so the row's surface shows.
const inlineUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-size: var(--text-detail);
  --diffs-line-height: 18px;
  --diffs-font-family: var(--font-mono, ui-monospace, monospace);
  background: transparent;
}`;

export function GitHubFileDiff({ patch }: { patch: string }) {
  registerAgentDiffTheme();
  const [themeType, setThemeType] = useState(pageThemeType);
  useEffect(() => {
    const theme = new MutationObserver(() => setThemeType(pageThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => theme.disconnect();
  }, []);
  const fileDiff = useMemo(() => setLanguageOverride(getSingularPatch(patch), "text"), [patch]);
  const options = useMemo(
    () => ({
      theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      themeType,
      diffStyle: "unified" as const,
      diffIndicators: "bars" as const,
      hunkSeparators: "line-info" as const,
      lineDiffType: "none" as const,
      overflow: "scroll" as const,
      preferredHighlighter: "shiki-js" as const,
      disableFileHeader: true,
      unsafeCSS: inlineUnsafeCSS,
    }),
    [themeType],
  );
  return <FileDiff fileDiff={fileDiff} options={options} />;
}
