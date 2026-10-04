// An opened shell call: a "Shell" card with the command line, its output
// and, when the command failed, its exit code.
import { t } from "../i18n";

export function ShellBlock({ command, output, exitCode }: { command?: string; output?: string; exitCode?: number }) {
  return (
    <div className="cv-shell">
      <div className="cv-shell__label">{t("shell.label")}</div>
      <pre className="cv-shell__body">
        {command && <span className="cv-shell__command">$ {command}</span>}
        {output && <span className="cv-shell__output">{output}</span>}
      </pre>
      {exitCode !== undefined && exitCode !== 0 && (
        <div className="cv-shell__exit">{t("shell.exit", { code: exitCode })}</div>
      )}
    </div>
  );
}
