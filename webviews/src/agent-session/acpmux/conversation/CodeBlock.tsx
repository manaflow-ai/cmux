// Fenced code inside a transcript, rendered by @pierre/diffs `File` with the pane's
// syntax theme (a ```diff fence is highlighted as a diff). Ported from
// manaflow-ai/codex-atlas-clone (src/conversation/CodeBlock.tsx).
import { useCallback } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { CodeBrackets, Copy, WrapLines } from "./icons";

/// Pierre paints its own lines; they are transparent so the card's fill shows through.
const codeUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: transparent;
  --diffs-light-bg: transparent;
  --diffs-font-size: 12px;
  --diffs-line-height: 20px;
  background: transparent;
}
[data-line] > span { top: 0; }
pre, code, [data-code], [data-content], [data-line] { background: transparent !important; --diffs-line-bg: transparent; }
`;

/// Header label Codex shows for a fence language.
const LANG_LABELS: Record<string, string> = {
  text: "Plain text",
  txt: "Plain text",
  python: "Python",
  py: "Python",
  json: "JSON",
  diff: "Diff",
  ts: "TypeScript",
  typescript: "TypeScript",
  js: "JavaScript",
  javascript: "JavaScript",
  swift: "Swift",
  sh: "Shell",
  bash: "Shell",
};

export function languageLabel(lang: string) {
  return LANG_LABELS[lang] ?? lang;
}

/// The pane's theme (applyAgentTheme) is light or dark; syntax colors follow it.
const paneThemeType = () => (document.documentElement.dataset.theme === "light" ? "light" : "dark");

export type CodeBlockProps = {
  code: string;
  /** Fence language (`python`, `json`, `diff`, `text`, …). */
  lang?: string;
  /** Header label; defaults to the language's display name. */
  label?: string;
};

/**
 * Fenced code card: language label with wrap and copy marks over a Pierre `File`.
 *
 * A callback ref drives the File: it creates the instance on mount and its cleanup
 * disposes it and empties the shadow root, so a remount never hydrates a stale one.
 */
export function CodeBlock({ code, lang = "text", label }: CodeBlockProps) {
  const host = useCallback(
    (el: HTMLElement | null) => {
      if (!el) return;
      registerAgentDiffTheme();
      const view = new PierreFile(
        {
          theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
          themeType: paneThemeType(),
          disableFileHeader: true,
          disableLineNumbers: true,
          overflow: "scroll",
          unsafeCSS: codeUnsafeCSS,
        },
        undefined,
        // React owns the host element: Pierre must not remove it on cleanUp.
        true,
      );
      // Shiki throws for a language the bundle does not ship; those draw as plain text.
      view.render({ fileContainer: el, file: { name: "snippet", contents: code, lang: (isHighlighted(lang) ? lang : "text") as never } });
      return () => {
        view.cleanUp();
        el.shadowRoot?.replaceChildren();
      };
    },
    [code, lang],
  );
  return (
    <div className="cv-codeblock">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{label ?? languageLabel(lang)}</span>
        <span className="cv-codeblock__actions">
          <WrapLines />
          <Copy />
        </span>
      </div>
      <DiffsHost ref={host} className="cv-codeblock__body" />
    </div>
  );
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
