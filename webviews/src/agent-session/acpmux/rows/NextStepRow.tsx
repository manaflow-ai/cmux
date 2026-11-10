import { memo, useContext } from "react";
import { callNative } from "../callNative";
import type { WrapUpTry } from "../conversation/nextStepAsk";
import { TurnActionsContext } from "../conversation/turnActions";
import { NextStepCard } from "../conversation/NextStepCard";
import { askKey } from "../conversation/waitingAskStore";
import { type RowProps } from "./rowProps";

const ignore = (p: Promise<unknown>) => void p.catch(() => undefined);

/// A wrap-up's Try on the click's gesture: a page in a new browser tab (a Tag Opener address
/// launches its build), a command in a new terminal, run.
export function openTry(tryIt: WrapUpTry) {
  if (tryIt.url) ignore(callNative("tab.open", { kind: "browser", text: tryIt.url, run: true }));
  else if (tryIt.command) ignore(callNative("tab.open", { kind: "terminal", text: tryIt.command, run: true }));
}

/// The report: a web address in a browser tab; a file in the pane's file tab, else as a page.
export function openReport(report: string) {
  if (/^https?:\/\//i.test(report)) {
    ignore(callNative("tab.open", { kind: "browser", text: report, run: true }));
    return;
  }
  const path = report.startsWith("file://") ? decodeURIComponent(new URL(report).pathname) : report;
  void callNative("file.open", { path, where: "tab" }).catch(() =>
    ignore(callNative("tab.open", { kind: "browser", text: "file://" + encodeURI(path), run: true })),
  );
}

/// A tagged ask the turn's answer ended on, as a card with its answers (conversation/NextStepCard.tsx).
export const NextStepRow = memo(
  function NextStepRow({ row }: RowProps) {
    const { answer, nextStepKey, asker } = useContext(TurnActionsContext);
    return row.nextStep ? (
      <NextStepCard
        ask={row.nextStep.ask}
        answer={row.nextStep.answer}
        superseded={row.nextStep.superseded}
        onAnswer={answer}
        registerKey={nextStepKey}
        answerKey={askKey(row)}
        asker={asker}
        onTry={openTry}
        onReport={openReport}
      />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
