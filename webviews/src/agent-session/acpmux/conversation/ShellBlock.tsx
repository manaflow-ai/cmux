// An opened shell call: a "Shell" card with the command line, its output (the end of a long one,
// with Show all output) and, when the command failed, its exit code.
import { useT } from "../i18n";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { OutputMore, useOutput } from "./toolOutput";

export function ShellBlock({
  id,
  command,
  output,
  exitCode,
}: {
  id?: string;
  command?: string;
  output?: string;
  exitCode?: number;
}) {
  const t = useT();
  const shown = useOutput(output);
  return (
    <div className="cv-shell" id={id} ref={menuPartRef({ command, output: shown.text })}>
      <div className="cv-shell__label">
        {t("shell.label")}
        {shown.text && <CopyButton text={shown.text} label={t("turn.copy")} />}
      </div>
      <pre className="cv-shell__body selectable">
        {command && <span className="cv-shell__command">$ {command}</span>}
        {shown.cut && (
          <span className="cv-output-cut" aria-hidden="true">
            …
          </span>
        )}
        {shown.shown && <span className="cv-shell__output">{shown.shown}</span>}
      </pre>
      <OutputMore output={shown} />
      {exitCode !== undefined && exitCode !== 0 && (
        <div className="cv-shell__exit">{t("shell.exit", { code: exitCode })}</div>
      )}
    </div>
  );
}
