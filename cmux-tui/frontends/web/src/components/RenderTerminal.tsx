import { memo, type CSSProperties } from "react";
import type { CmuxClient, Id, RenderRow } from "cmux/browser";
import { useRenderTerminal } from "../hooks/useRenderTerminal";
import { t } from "../i18n";
import { runPresentation } from "../lib/renderStyles";
import { TerminalFrame } from "./TerminalFrame";

interface RenderTerminalProps {
  client: CmuxClient;
  surface: Id;
  active: boolean;
  error: string | null;
  focusOnMount?: boolean;
  onError(error: Error): void;
}

interface RenderRowViewProps {
  row: RenderRow;
  index: number;
  defaultFg: string;
  defaultBg: string;
}

const RenderRowView = memo(function RenderRowView({ row, index, defaultFg, defaultBg }: RenderRowViewProps) {
  return (
    <div
      className="render-row"
      style={{ top: `calc(var(--render-cell-height) * ${index})` }}
      data-row={row.row}
    >
      {row.runs.map((run, runIndex) => {
        const presentation = runPresentation(run, defaultFg, defaultBg);
        return (
          <span className={presentation.className} style={presentation.style} key={runIndex}>
            {run.text}
          </span>
        );
      })}
    </div>
  );
});

export function RenderTerminal({
  client,
  surface,
  active,
  error,
  focusOnMount = false,
  onError,
}: RenderTerminalProps) {
  const {
    terminalRef,
    focused,
    model,
    history,
    backToLive,
    sendKey,
    sendText,
  } = useRenderTerminal({ client, surface, active, focusOnMount, onError });
  const rows = history.active ? history.rows : (model?.rows ?? []);
  const defaultFg = model?.defaultFg ?? "var(--terminal-foreground)";
  const defaultBg = model?.defaultBg ?? "var(--terminal-background)";
  const cols = model?.size.cols ?? 0;
  const gridStyle = {
    width: `calc(var(--render-cell-width) * ${cols})`,
    height: `calc(var(--render-cell-height) * ${rows.length})`,
    backgroundColor: defaultBg,
  } satisfies CSSProperties;
  const cursor = model?.cursor;
  const cursorStyle = cursor === undefined ? undefined : {
    left: `calc(var(--render-cell-width) * ${cursor.x})`,
    top: `calc(var(--render-cell-height) * ${cursor.y})`,
    color: cursor.color ?? "var(--terminal-cursor)",
  } satisfies CSSProperties;

  return (
    <TerminalFrame
      client={client}
      focused={focused}
      error={error}
      onKey={sendKey}
      onSend={sendText}
    >
      <div
        className="terminal-host render-terminal-host"
        ref={terminalRef}
      >
        <div
          className={`render-scroll${history.active ? " history" : " live"}`}
          data-render-scroll
        >
          <div className="render-grid" style={gridStyle} role="log">
            {rows.map((row, index) => (
              <RenderRowView
                row={row}
                index={index}
                defaultFg={defaultFg}
                defaultBg={defaultBg}
                key={`${history.active ? "history" : "live"}-${row.row}`}
              />
            ))}
            {!history.active && cursor?.visible && cursorStyle !== undefined && (
              <span
                aria-hidden="true"
                className={`render-cursor render-cursor-${cursor.style}${cursor.blink ? " render-cursor-blink" : ""}${focused ? "" : " unfocused"}`}
                style={cursorStyle}
              />
            )}
          </div>
        </div>
        <textarea
          className="render-input"
          data-render-input
          aria-label={t("terminalInput")}
          autoCapitalize="off"
          autoComplete="off"
        autoCorrect="off"
        autoFocus={focusOnMount}
        spellCheck={false}
        />
        <span className="render-metric-probe" data-render-probe aria-hidden="true">W</span>
        {history.active && (
          <button
            className="back-to-live"
            type="button"
            onPointerDown={(event) => event.preventDefault()}
            onClick={backToLive}
          >
            {t("backToLive")}
          </button>
        )}
        {history.active && history.loading && history.rows.length === 0 && (
          <div className="scrollback-status" role="status">{t("loadingScrollback")}</div>
        )}
      </div>
    </TerminalFrame>
  );
}
