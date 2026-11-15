// A shell mode command's block in the transcript: the command, its status in one fixed slot
// (Stop while it runs, then its exit status and time), its output, whole up to `OUTPUT_BOX_LINES`
// lines and scrolling inside a box that tall past them (outputScrollBox.css; its newest line in
// view), and "Open in terminal", which types the command into a new terminal tab in the same folder
// without running it.
import { useContext, useEffect, useLayoutEffect, useRef } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { OUTPUT_SCROLL_BOX } from "../conversation/blockPartsModel";
import { Check, Spinner } from "../conversation/icons";
import { moreBelow, useMoreBelowOn } from "../conversation/moreBelow";
import { ShellActionsContext } from "./shellRowModel";
import "../conversation/outputScrollBox.css";

/// `expanded` and `onToggleActivity` are the transcript's row props: the block has nothing to open.
export function ShellRow({ row }: { row: AcpmuxRow; expanded?: boolean; onToggleActivity?: (id: string) => void }) {
  const t = useT();
  const actions = useContext(ShellActionsContext);
  const run = row.shell;
  const output = run?.output.replace(/\n$/, "") ?? "";
  const box = useRef<HTMLPreElement>(null);
  useMoreBelowOn(box, output);
  // While it runs, the box keeps its newest line in view unless the reader scrolled up from the end;
  // scrolling back to the end follows again.
  const away = useRef(false);
  const running = run?.status === "running";
  useEffect(() => {
    const node = box.current;
    if (!node || !running) return;
    const onScroll = () => {
      away.current = moreBelow(node);
    };
    node.addEventListener("scroll", onScroll, { passive: true });
    return () => node.removeEventListener("scroll", onScroll);
  }, [box, running]);
  useLayoutEffect(() => {
    const node = box.current;
    if (node && running && !away.current) node.scrollTop = node.scrollHeight;
  }, [box, output, running]);
  if (!run) return null;
  const seconds = run.endedAt !== undefined ? (run.endedAt - run.startedAt) / 1000 : undefined;
  const time = seconds === undefined ? "" : seconds < 10 ? `${seconds.toFixed(1)}s` : `${Math.round(seconds)}s`;
  return (
    <div className="acpmux-shell-block" data-status={run.status}>
      <div className="acpmux-shell-block-head">
        <span className="acpmux-shell-block-glyph" aria-hidden="true">
          !
        </span>
        <code className="acpmux-shell-block-command">{run.command}</code>
        <span className="acpmux-shell-block-status">
          {run.status === "running" ? (
            actions ? (
              <button type="button" className="acpmux-shell-block-stop" onClick={() => actions.stop(run.id)}>
                <Spinner size={12} />
                {t("shell.stop")}
                <kbd>⌃C</kbd>
              </button>
            ) : (
              <Spinner size={12} />
            )
          ) : (
            <>
              {run.status === "done" ? (
                <span className="acpmux-shell-block-ok">
                  <Check size={14} />
                  <span className="visually-hidden">{t("shell.succeeded")}</span>
                </span>
              ) : (
                <span className="acpmux-shell-block-failed">
                  {run.status === "stopped"
                    ? t("shell.stopped")
                    : run.exitCode !== undefined
                      ? t("shell.exit", { code: run.exitCode })
                      : t("shell.failed")}
                </span>
              )}
              {time && <span className="acpmux-shell-block-time">{time}</span>}
            </>
          )}
        </span>
        {/* No actions (a read-only transcript, conversation/GuestActionsBoundary.tsx): no Stop, no Open. */}
        {actions && (
          <button type="button" className="acpmux-shell-block-open" onClick={() => actions.openInTerminal(run)}>
            {t("shell.openInTerminal")}
          </button>
        )}
      </div>
      {(output || run.error) && (
        <pre
          ref={box}
          className={`acpmux-shell-block-output ${OUTPUT_SCROLL_BOX} selectable`}
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll box to read it with arrow keys.
          tabIndex={0}
          aria-label={t("handoff.tool_output")}
        >
          {run.truncated && (
            <span className="acpmux-shell-block-cut" aria-hidden="true">
              …
            </span>
          )}
          {output}
          {run.error && <span className="acpmux-shell-block-error">{run.error}</span>}
        </pre>
      )}
    </div>
  );
}
