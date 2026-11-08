import { useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { treeText, valueTree } from "./valueTree";
import { parseJSONValue } from "./toolResult";

/// A bounded, harness-neutral rendering of Pi custom tool calls.  Pi's
/// `renderCall`/`renderResult` components are TUI-only, so ACP cannot carry
/// their pixels; keeping the structured call and result in one quiet row
/// preserves the useful content without pretending it is HTML.
export function PiRichRow({ item }: { item: AcpmuxActivity }) {
  const tool = item.tool;
  const input = useMemo(() => {
    if (!tool?.inputSummary) return undefined;
    try {
      return JSON.parse(tool.inputSummary);
    } catch {
      return tool.inputSummary;
    }
  }, [tool?.inputSummary]);
  const output = useMemo(() => parseJSONValue(tool?.output) ?? tool?.output, [tool?.output]);
  if (!tool) return null;
  const inputText = input === undefined ? "" : treeText(valueTree(input));
  const outputText = output === undefined || output === "" ? "" : treeText(valueTree(output));
  return (
    <section className="cv-pi-rich-row" data-tool-id={tool.id}>
      <header className="cv-pi-rich-row__head">
        <span className="cv-pi-rich-row__mark" aria-hidden="true">✦</span>
        <strong>{tool.title}</strong>
        <span className="cv-pi-rich-row__status">{tool.status}</span>
      </header>
      {inputText && <pre className="cv-pi-rich-row__body">{inputText}</pre>}
      {outputText && <pre className="cv-pi-rich-row__body is-output">{outputText}</pre>}
    </section>
  );
}
