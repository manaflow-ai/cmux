"use client";

import { useTranslations } from "next-intl";
import type { Pane, TextboxState } from "./protocol";
import { SurfaceStore } from "./surface-store";
import { TerminalPane } from "./terminal-pane";

function TextboxMirror({ state }: { state: TextboxState }) {
  const selStart = Math.max(0, Math.min(state.selStart, state.text.length));
  const before = state.text.slice(0, selStart);
  const after = state.text.slice(selStart);
  return (
    <pre className="m-0 h-full w-full overflow-auto whitespace-pre-wrap break-words p-3 font-mono text-[13px] leading-5 text-neutral-200">
      {before}
      <span
        className="inline-block h-[1.1em] w-[2px] translate-y-[0.15em] animate-pulse rounded-sm align-baseline"
        style={{ background: "#2d8cff" }}
      />
      {after}
    </pre>
  );
}

export function PaneTile({
  pane,
  store,
  fontSize,
  textbox,
}: {
  pane: Pane;
  store: SurfaceStore;
  fontSize: number;
  textbox: TextboxState | null;
}) {
  const t = useTranslations("share");

  if (pane.kind === "terminal" && pane.surfaceId) {
    return (
      <TerminalPane
        surfaceId={pane.surfaceId}
        cols={pane.cols ?? 80}
        rows={pane.rows ?? 24}
        fontSize={fontSize}
        store={store}
      />
    );
  }

  const label =
    pane.kind === "browser"
      ? t("pane.browser")
      : pane.kind === "textbox"
        ? t("pane.textbox")
        : t("pane.other");

  return (
    <div className="flex h-full w-full flex-col bg-neutral-900">
      <div className="flex items-center gap-2 border-b border-neutral-800 px-3 py-1.5">
        <span className="text-[11px] uppercase tracking-wide text-neutral-500">
          {label}
        </span>
        <span className="truncate text-[12px] text-neutral-300">
          {pane.title ?? ""}
        </span>
        {pane.kind === "browser" && pane.url ? (
          <span className="truncate text-[11px] text-neutral-500">
            {pane.url}
          </span>
        ) : null}
      </div>
      {pane.kind === "textbox" && textbox ? (
        <TextboxMirror state={textbox} />
      ) : (
        <div className="flex flex-1 items-center justify-center text-[12px] text-neutral-600">
          {t("pane.placeholder")}
        </div>
      )}
    </div>
  );
}
