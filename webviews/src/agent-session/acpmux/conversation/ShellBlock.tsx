// An opened shell call: a "Shell" card with the folder it ran in (a leading `cd ~/wt/lanes/x &&`
// reads as "x" beside the label), the command line, its output (the end of a long one, with Show
// all output) and, when the command failed, its exit code.
import { useT } from "../i18n";
import { commandFolder } from "./commandFolder";
import { CopyButton } from "./CopyButton";
import { menuPartRef } from "./menuParts";
import { OutputMore, useOutput } from "./toolOutput";

export function ShellBlock({
  id,
  command,
  output,
  exitCode,
  reveal,
}: {
  id?: string;
  /** Bumped when Find in Chat reveals the call: shows the whole output, not only its end. */
  reveal?: number;
  command?: string;
  output?: string;
  exitCode?: number;
}) {
  const t = useT();
  const shown = useOutput(output, reveal);
  const { folder, rest } = command ? commandFolder(command) : { folder: undefined, rest: undefined };
  return (
    <div className="cv-shell" id={id} ref={menuPartRef({ command, output: shown.text })}>
      <div className="cv-shell__label">
        <span className="cv-shell__title">
          {t("shell.label")}
          {folder && (
            <span
              className="cv-shell__folder"
              data-find-skip
              /* tooltip-allow: the full `cd …` prefix shows nowhere else (the command line drops it) */
              title={command!.slice(0, command!.length - rest!.length).trim()}
            >
              {folder}
            </span>
          )}
        </span>
        {shown.text && <CopyButton text={shown.text} label={t("turn.copy")} />}
      </div>
      <pre className="cv-shell__body selectable">
        {rest && <span className="cv-shell__command">$ {rest}</span>}
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
