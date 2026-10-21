// A fence's two cards (StreamingCode.tsx): the plain card an open fence draws and the highlighted
// card that replaces it when the fence closes, in a column as wide as the streaming harness's
// transcript, for the streaming reply's code block, a short one and one with a line wider than the
// column. `window.__codeHandoff.measure()` waits for Pierre to paint the highlighted cards' lines,
// then reports each card's height and its parts' (code-handoff-height.test.ts reads it).
import { createRoot } from "react-dom/client";
import { CodeBlock, loadHighlightedCode } from "../../src/agent-session/acpmux/conversation/CodeBlock";
import { PlainCode } from "../../src/agent-session/acpmux/conversation/StreamingCode";
import { REPLY } from "../../src/agent-session/acpmux/conversation/streamingTextFixture";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

/// The reply's fence as the transcript hands it to the card, a short one and one that scrolls sideways.
const [, replyLang = "text", replyCode = ""] = /```(\w*)\n([\s\S]*?)\n```/.exec(REPLY) ?? [];
const FENCES = {
  reply: { lang: replyLang, code: replyCode },
  short: { lang: "ts", code: "const delay = policy.next();\nawait sleep(delay);" },
  wide: { lang: "ts", code: `const banner = "${"=".repeat(160)}";\nconsole.log(banner);` },
};
export type FenceName = keyof typeof FENCES;

/// The streaming harness's transcript column at its 900 px viewport.
const COLUMN = 704;

export type CardHeights = { card: number; header: number; body: number; lines: number };
export type FenceReport = {
  plain: CardHeights;
  highlighted: CardHeights;
  /// Whether the highlighted card's row scrolls sideways (its widest line is wider than the row).
  scrolls: boolean;
};

const height = (el: Element | null | undefined) => el?.getBoundingClientRect().height ?? -1;

function heights(card: HTMLElement | null): CardHeights {
  const body = card?.querySelector<HTMLElement>(".cv-codeblock__body");
  const root = body?.shadowRoot ?? body;
  return {
    card: height(card),
    header: height(card?.querySelector(".cv-codeblock__header")),
    body: height(body),
    lines: root?.querySelectorAll(".cv-code-plain__line, [data-line]").length ?? 0,
  };
}

createRoot(document.getElementById("root")!).render(
  <div className="cv-md" style={{ width: COLUMN }}>
    {Object.entries(FENCES).map(([name, { code, lang }]) => (
      <div key={name} data-fence={name}>
        <div data-card="plain">
          <PlainCode code={code} lang={lang} />
        </div>
        <div data-card="highlighted">
          <CodeBlock code={code} lang={lang} />
        </div>
      </div>
    ))}
  </div>,
);

(window as unknown as { __codeHandoff: unknown }).__codeHandoff = {
  async measure(): Promise<Record<FenceName, FenceReport>> {
    await loadHighlightedCode();
    const card = (fence: string, kind: string) =>
      document.querySelector<HTMLElement>(`[data-fence="${fence}"] [data-card="${kind}"] .cv-codeblock`);
    const painted = () =>
      Object.keys(FENCES).every((fence) =>
        card(fence, "highlighted")?.querySelector("diffs-container")?.shadowRoot?.querySelector("[data-line]"),
      );
    while (!painted()) await new Promise(requestAnimationFrame);
    await new Promise(requestAnimationFrame);
    const report = {} as Record<FenceName, FenceReport>;
    for (const fence of Object.keys(FENCES) as FenceName[]) {
      const highlighted = card(fence, "highlighted");
      const row = highlighted?.querySelector("diffs-container")?.shadowRoot?.querySelector<HTMLElement>("[data-code]");
      report[fence] = {
        plain: heights(card(fence, "plain")),
        highlighted: heights(highlighted),
        scrolls: !!row && row.scrollWidth > row.clientWidth,
      };
    }
    return report;
  },
};
