import { memo, type CSSProperties } from "react";
import type { CmuxClient, Id, RenderRow } from "cmux/raw";
import { useRenderTerminal } from "../hooks/useRenderTerminal";
import { t } from "../i18n";
import { projectRenderGraphicsToRows } from "../lib/scrollback";
import { renderAttrs, runPresentation } from "../lib/renderStyles";
import { RenderGraphics } from "./RenderGraphics";
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
  mode?: "plain" | "background" | "foreground";
}

const RenderRowView = memo(function RenderRowView({
  row,
  index,
  defaultFg,
  defaultBg,
  mode = "plain",
}: RenderRowViewProps) {
  const backgroundOnly = mode === "background";
  return (
    <div
      aria-hidden={backgroundOnly || undefined}
      className={backgroundOnly ? "render-row-background" : "render-row"}
      style={{
        top: `calc(var(--render-cell-height) * ${index})`,
        ...(backgroundOnly ? { backgroundColor: defaultBg } : {}),
      }}
      {...(backgroundOnly ? {} : { "data-row": row.row })}
    >
      {row.runs.map((run, runIndex) => {
        const presentation = runPresentation(run, defaultFg, defaultBg);
        const usesDefaultBackground =
          run.bg === null && (run.attrs & renderAttrs.inverse) === 0;
        const style = backgroundOnly
          ? {
            color: "transparent",
            backgroundColor: usesDefaultBackground
              ? "transparent"
              : presentation.style.backgroundColor,
            ...(presentation.style.width === undefined ? {} : { width: presentation.style.width }),
          }
          : mode === "foreground"
            ? { ...presentation.style, backgroundColor: "transparent" }
            : presentation.style;
        return (
          <span
            className={backgroundOnly ? "render-run" : presentation.className}
            style={style}
            key={runIndex}
          >
            {run.text}
          </span>
        );
      })}
    </div>
  );
});

interface RenderRowsViewProps {
  defaultBg: string;
  defaultFg: string;
  keyPrefix: string;
  mode?: "plain" | "background" | "foreground";
  rows: readonly RenderRow[];
}

const RenderRowsView = memo(function RenderRowsView({
  defaultBg,
  defaultFg,
  keyPrefix,
  mode = "plain",
  rows,
}: RenderRowsViewProps) {
  return rows.map((row, index) => (
    <RenderRowView
      defaultBg={defaultBg}
      defaultFg={defaultFg}
      index={index}
      key={`${keyPrefix}-${row.row}`}
      mode={mode}
      row={row}
    />
  ));
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
  const projectedGraphics = history.active
    ? projectRenderGraphicsToRows(model?.graphics, rows, model?.historyEpoch, history.epoch)
    : model?.graphics;
  const layeredGraphics = projectedGraphics !== undefined
    && projectedGraphics.images.length > 0
    && projectedGraphics.placements.length > 0
    ? projectedGraphics
    : undefined;
  const rowKeyPrefix = history.active ? "history" : "live";

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
            {layeredGraphics === undefined ? (
              <RenderRowsView
                defaultFg={defaultFg}
                defaultBg={defaultBg}
                keyPrefix={rowKeyPrefix}
                rows={rows}
              />
            ) : (
              <RenderGraphics
                backgroundChildren={(
                  <RenderRowsView
                    defaultBg={defaultBg}
                    defaultFg={defaultFg}
                    keyPrefix={`${rowKeyPrefix}-background`}
                    mode="background"
                    rows={rows}
                  />
                )}
                graphics={layeredGraphics}
                plainChildren={(
                  <RenderRowsView
                    defaultBg={defaultBg}
                    defaultFg={defaultFg}
                    keyPrefix={`${rowKeyPrefix}-plain`}
                    rows={rows}
                  />
                )}
              >
                <RenderRowsView
                  defaultBg={defaultBg}
                  defaultFg={defaultFg}
                  keyPrefix={rowKeyPrefix}
                  mode="foreground"
                  rows={rows}
                />
              </RenderGraphics>
            )}
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
