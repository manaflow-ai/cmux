import { useEffect, useRef } from "react";
import { useT } from "../i18n";
import { shownPath, touchedFiles, type ReplayTouch } from "./timeline";

/// The files and commands a replayed chat touched by replay time, beside its transcript (Leo,
/// 2026-11-19: "with the files and commands it touched"). The lists grow as the replay plays, as
/// the transcript does: a file once, marked Edited once a call changed it, and every command in
/// the order it ran. A row jumps the replay to its call.
export function ReplayTouches({
  touches,
  shown,
  cwd,
  onSeek,
}: {
  /** Every touch in the chat, in call order (ReplayTimeline.touches). */
  touches: readonly ReplayTouch[];
  /** How many of them happened by replay time. */
  shown: number;
  cwd?: string;
  onSeek: (time: number) => void;
}) {
  const t = useT();
  const sofar = touches.slice(0, shown);
  const files = touchedFiles(sofar);
  const commands = sofar.filter((touch) => touch.type === "command");
  const latest = sofar.at(-1);
  // The newest row stays in view as the lists grow, without moving the panel's own scroll otherwise.
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    panel.current?.querySelector("[aria-current='true']")?.scrollIntoView({ block: "nearest" });
  }, [shown]);

  return (
    <aside ref={panel} className="acpmux-replay-touches" aria-label={t("replay.touches")}>
      {sofar.length === 0 && <p className="acpmux-replay-touches-none">{t("replay.touchesNone")}</p>}
      {files.length > 0 && (
        <section>
          <h3 className="acpmux-replay-touches-heading">
            {t("replay.files")} <span className="acpmux-replay-touches-count">{files.length}</span>
          </h3>
          <ul>
            {files.map((file) => (
              <li key={file.path}>
                <button
                  type="button"
                  className="acpmux-replay-touch"
                  aria-current={latest?.type === "file" && latest.text === file.path}
                  title={file.path}
                  onClick={() => onSeek(file.last.time)}
                >
                  <span className="acpmux-replay-touch-text">{shownPath(file.path, cwd)}</span>
                  <span className="acpmux-replay-touch-verb" data-edited={file.edited}>
                    {file.edited ? t("replay.edited") : t("replay.read")}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
      {commands.length > 0 && (
        <section>
          <h3 className="acpmux-replay-touches-heading">
            {t("replay.commands")} <span className="acpmux-replay-touches-count">{commands.length}</span>
          </h3>
          <ul>
            {commands.map((command) => (
              <li key={command.seq}>
                <button
                  type="button"
                  className="acpmux-replay-touch"
                  aria-current={command === latest}
                  title={command.text}
                  onClick={() => onSeek(command.time)}
                >
                  <span className="acpmux-replay-touch-text acpmux-replay-touch-command">{command.text}</span>
                  {command.failed && (
                    <span className="acpmux-replay-touch-verb" data-failed="true">
                      {t("replay.commandFailed")}
                    </span>
                  )}
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
    </aside>
  );
}
