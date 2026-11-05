// An opened tool call as Claude's tool sheet draws it (Leo, 2026-11-05: "I saw this format for a
// tool call a session did idk if we also wanna model like that"): an Input card with one labeled
// field per argument (its key small and monospace, its value as wrapped prose, Markdown when it
// reads as Markdown, a small tree for a nested value), then Output with a copy button on its
// heading. Generic tool rows (ToolRow.tsx) and MCP calls (McpCallRows.tsx) open to it; shell,
// edit and the cmux server's own calls keep their own bodies. The call's request as it came stays
// behind Raw where a caller passes one (McpCallRows.tsx).
import { memo, type ReactNode, useMemo } from "react";
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";
import { Markdown } from "./Markdown";
import { useMoreBelow } from "./moreBelow";
import { ToolOutput } from "./ToolOutputBody";
import type { ToolResult } from "./toolResult";
import type { InputField } from "./toolInputFields";

function FieldValue({ field }: { field: InputField }) {
  const box = useMoreBelow<HTMLDivElement>(field.text);
  switch (field.look) {
    case "markdown":
      return (
        <div ref={box} className="cv-tool-detail__value is-markdown selectable">
          <Markdown plainCode>{field.text}</Markdown>
        </div>
      );
    case "tree":
      return (
        <div ref={box} className="cv-tool-detail__value is-tree selectable">
          <pre>{field.text}</pre>
        </div>
      );
    default:
      return (
        <div ref={box} className={`cv-tool-detail__value is-${field.look} selectable`}>
          {field.text}
        </div>
      );
  }
}

/// The Input card: one labeled field per argument, a hairline between them.
export function ToolInputFields({ fields }: { fields: readonly InputField[] }) {
  return (
    <div className="cv-tool-detail__fields">
      {fields.map((field) => (
        <div key={field.key} className="cv-tool-detail__field">
          <code className="cv-tool-detail__key" data-find-skip>
            {field.key}
          </code>
          <FieldValue field={field} />
        </div>
      ))}
    </div>
  );
}

/// An opened call: Input, then Output with its copy button. `head`: what goes above both (an MCP
/// call's machine name); `after`: what goes below (Raw, a reaction reply). A part with nothing in
/// it is left out; `outputHead` names the output part when it is not a plain result (a hook's block).
export const ToolDetail = memo(function ToolDetail({
  id,
  fields,
  result,
  reveal,
  head,
  after,
  outputHead,
}: {
  id: string;
  fields?: readonly InputField[];
  result?: ToolResult;
  reveal: number;
  head?: ReactNode;
  after?: ReactNode;
  outputHead?: string;
}) {
  const t = useT();
  const output = result?.text.trim() ? result : undefined;
  const copy = useMemo(() => output?.text ?? "", [output]);
  return (
    <div id={id} className="cv-tool-detail">
      {head}
      {fields && fields.length > 0 && (
        <section className="cv-tool-detail__part">
          <div className="cv-tool-detail__head" data-find-skip>
            {t("tools.detail.input")}
          </div>
          <ToolInputFields fields={fields} />
        </section>
      )}
      {(output || outputHead) && (
        <section className="cv-tool-detail__part">
          <div className="cv-tool-detail__head" data-find-skip>
            <span>{outputHead ?? t("tools.detail.output")}</span>
            {output && (
              <CopyButton
                text={copy}
                label={t("tools.detail.copyOutput")}
                className="cv-codeblock__action cv-tool-detail__copy"
                size={14}
              />
            )}
          </div>
          {output && <ToolOutput result={output} reveal={reveal} ownCopy={false} />}
        </section>
      )}
      {after}
    </div>
  );
});
