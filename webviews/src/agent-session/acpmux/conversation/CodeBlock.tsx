// Fenced code inside a transcript, rendered by @pierre/diffs `File` with the pane's
// syntax theme (a ```diff fence is highlighted as a diff). Ported from
// the agent-pane reference prototype (src/conversation/CodeBlock.tsx).
import { useLayoutEffect, useRef, useState } from "react";
import { DIFFS_TAG_NAME, File as PierreFile } from "@pierre/diffs";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, diffUnsafeCSS, registerAgentDiffTheme } from "../diffTheme";
import { isHighlighted } from "../shikiLanguages";
import { copyText } from "./clipboard";
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

/// Header label shown for a fence language.
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
 * Fenced code card: language label with wrap and copy over a Pierre `File`.
 *
 * One File lives as long as the card. A streaming fence grows on every chunk, so new text
 * re-renders the same instance instead of building another; a theme switch on the page
 * (applyAgentTheme sets `data-theme`) changes its syntax colors in place.
 */
export function CodeBlock({ code, lang = "text", label }: CodeBlockProps) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<PierreFile | undefined>(undefined);
  const [wrap, setWrap] = useState(false);
  const [copied, setCopied] = useState(false);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el) return;
    registerAgentDiffTheme();
    const file = new PierreFile(
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
    view.current = file;
    const theme = new MutationObserver(() => file.setThemeType(paneThemeType()));
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      theme.disconnect();
      view.current = undefined;
      file.cleanUp();
      el.shadowRoot?.replaceChildren();
    };
  }, []);
  useLayoutEffect(() => {
    const el = host.current;
    const file = view.current;
    if (!el || !file) return;
    file.setOptions({ ...file.options, overflow: wrap ? "wrap" : "scroll" });
    // Shiki throws for a language the bundle does not ship; those draw as plain text.
    file.render({
      fileContainer: el,
      file: { name: "snippet", contents: code, lang: (isHighlighted(lang) ? lang : "text") as never },
    });
  }, [code, lang, wrap]);
  return (
    <div className="cv-codeblock">
      <div className="cv-codeblock__header">
        <CodeBrackets size={17} strokeWidth={1.2} />
        <span>{label ?? languageLabel(lang)}</span>
        <span className="cv-codeblock__actions">
          <button
            type="button"
            className="cv-codeblock__action"
            aria-pressed={wrap}
            aria-label="Wrap lines"
            title="Wrap lines"
            onClick={() => setWrap((value) => !value)}
          >
            <WrapLines />
          </button>
          <button
            type="button"
            className="cv-codeblock__action"
            aria-label={copied ? "Copied" : "Copy code"}
            title={copied ? "Copied" : "Copy code"}
            onClick={() => void copyText(code).then(() => setCopied(true))}
          >
            <Copy />
          </button>
        </span>
      </div>
      <DiffsHost ref={host} className="cv-codeblock__body selectable" />
    </div>
  );
}

/// Pierre's host element (`<diffs-container>`); it attaches its own shadow root.
const DiffsHost = DIFFS_TAG_NAME as unknown as "div";
