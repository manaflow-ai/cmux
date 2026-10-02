// Fenced code inside a transcript, rendered by @pierre/diffs `File` (a ```diff fence is
// highlighted as a diff). The card holds window.__atlasReady until Pierre has painted it.
import { useCallback } from "react";
import { DIFFS_TAG_NAME, File as PierreFile, FileDiff as PierreFileDiff, parsePatchFiles } from "@pierre/diffs-port";
import { CODEX_DIFF_THEME, registerCodexDiffTheme } from "../changes/theme";
import { diffUnsafeCSS } from "../changes/diffStyles";
import { trackRender } from "./ready";
import { CodeBrackets, Copy, WrapLines } from "./icons";

registerCodexDiffTheme();

/** Card background; Pierre paints its own lines, so the color is repeated inside the shadow root. */
const CODE_BG = "#373833";
const codeUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-dark-bg: ${CODE_BG};
  --diffs-font-size: 12px;
  --diffs-line-height: 20px;
  background: ${CODE_BG};
}
[data-line] > span { top: 0; }
pre, code, [data-code], [data-content], [data-line] { background: ${CODE_BG} !important; --diffs-line-bg: ${CODE_BG}; }
`;

/** Header label Codex shows for a fence language. */
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

/** File extension Pierre expects for a fence language (it resolves highlighting by name). */
const EXTENSIONS: Record<string, string> = {
  text: "txt",
  python: "py",
  typescript: "ts",
  javascript: "js",
  bash: "sh",
};

export function languageLabel(lang: string) {
  return LANG_LABELS[lang] ?? lang;
}

export type CodeBlockProps = {
  code: string;
  /** Shiki language id (`python`, `json`, `diff`, `text`, …). */
  lang?: string;
  /** Header label; defaults to the language's display name. */
  label?: string;
  /** Show line numbers (off for chat code fences). */
  lineNumbers?: boolean;
  wrap?: boolean;
};

/**
 * Fenced code card: language label with wrap / copy buttons over a Pierre `File`.
 *
 * The File is driven from a callback ref instead of the React wrapper: the ref creates the
 * instance on mount (registering a pending render that Pierre's onPostRender settles) and
 * its cleanup disposes it and empties the shadow root. (Under
 * StrictMode the React wrapper re-attaches to a shadow root still holding the first
 * instance's empty <pre>, hydrates it as prerendered and never paints.)
 */
export function CodeBlock({ code, lang = "text", label, lineNumbers = false, wrap = false }: CodeBlockProps) {
  const host = useCallback(
    (el: HTMLElement | null) => {
      if (!el) return;
      // Hold window.__atlasReady until Pierre has painted (or the card unmounts).
      const painted = trackRender();
      const view = new PierreFile(
        {
          theme: CODEX_DIFF_THEME,
          themeType: "dark",
          disableFileHeader: true,
          disableLineNumbers: !lineNumbers,
          overflow: wrap ? "wrap" : "scroll",
          unsafeCSS: codeUnsafeCSS,
          onPostRender: painted,
        },
        undefined,
        // React owns the host element: Pierre must not remove it on cleanUp.
        true,
      );
      view.render({
        fileContainer: el,
        file: { name: `snippet.${EXTENSIONS[lang] ?? lang}`, contents: code, lang: lang as never },
      });
      return () => {
        view.cleanUp();
        el.shadowRoot?.replaceChildren();
        painted();
      };
    },
    [code, lang, lineNumbers, wrap],
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

/** Pierre's host element (`<diffs-container>`); it attaches its own shadow root. */
const DiffsHost = DIFFS_TAG_NAME as unknown as "div";

/** Diff card body: the edit's own colors (sampled on live-freestyle-edit-diff-expanded.png). */
const DIFF_BG = "#30312c";
const diffCardUnsafeCSS = `${diffUnsafeCSS}
:host {
  --diffs-font-size: 12px;
  --diffs-line-height: 22px;
}
`;

/**
 * The body of an "Edited file" row: the patch in Pierre's diff view (unified, bars beside
 * changed lines' numbers, Codex colors), driven from a callback ref like `CodeBlock`.
 * `diff` is the patch's hunks without file headers, as fileChange items carry it.
 */
export function DiffBlock({ name, diff }: { name: string; diff: string }) {
  const host = useCallback(
    (el: HTMLElement | null) => {
      if (!el) return;
      const fileDiff = parsePatchFiles(`--- a/${name}\n+++ b/${name}\n${diff}`)[0]?.files[0];
      if (!fileDiff) return;
      const painted = trackRender();
      const view = new PierreFileDiff(
        {
          theme: CODEX_DIFF_THEME,
          themeType: "dark",
          diffStyle: "unified",
          diffIndicators: "bars",
          hunkSeparators: "simple",
          disableFileHeader: true,
          overflow: "scroll",
          unsafeCSS: diffCardUnsafeCSS,
          onPostRender: painted,
        },
        undefined,
        true,
      );
      view.render({ fileContainer: el, fileDiff });
      return () => {
        view.cleanUp();
        el.shadowRoot?.replaceChildren();
        painted();
      };
    },
    [name, diff],
  );
  return <DiffsHost ref={host} className="cv-diff__body" style={{ background: DIFF_BG }} />;
}
