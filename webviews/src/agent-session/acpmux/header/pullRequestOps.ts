import { useEffect, useRef, useState } from "react";
import { translate, useT, type StringKey, type Translate } from "../i18n";
import type { HeaderCheck, HeaderPullRequest } from "./headerState";
import type { Merging, MergeResult } from "./PullRequestMerge";

export function readyToMerge(pr: HeaderPullRequest) {
  return (
    pr.state === "open" &&
    pr.mergeable === "mergeable" &&
    pr.review !== "changes_requested" &&
    pr.review !== "review_required" &&
    (pr.checks.state === "passing" || pr.checks.state === "none")
  );
}

export function checkPresentation(check: HeaderCheck, t: Translate = translate): string {
  const marker = check.state === "failed" ? "✕" : check.state === "pending" ? "…" : "✓";
  const base = check.onBase === true ? ` ${t("header.prCheckOnBase")}` : "";
  return `${marker} ${check.name}${base}`;
}

/// The status text and compact badge shared by the DOM chip and native row. Aggregate state
/// remains authoritative when individual check rows are missing or incomplete.
export function pullRequestStatus(pr: HeaderPullRequest, t: Translate): { label: string; badge: string } {
  const stateKeys: Record<string, StringKey> = {
    open: "header.prState.open",
    draft: "header.prState.draft",
    merged: "header.prState.merged",
    closed: "header.prState.closed",
  };
  const state = stateKeys[pr.state] ? t(stateKeys[pr.state]!) : pr.state;
  const failedRows = pr.checkList.filter((check) => check.state === "failed").length;
  const pendingRows = pr.checkList.filter((check) => check.state === "pending").length;
  const { passed, total } = pr.checks;
  const hasFailed = pr.checks.state === "failing" || failedRows > 0;
  const hasPending = pr.checks.state === "pending" || pendingRows > 0;
  const onBase = Math.max(
    pr.checks.failingOnBase ?? 0,
    pr.checkList.filter((check) => check.state === "failed" && check.onBase === true).length,
  );
  const label =
    total === 0
      ? t("header.pullRequestLabel", { number: pr.number, state })
      : failedRows > 0
        ? t("header.pullRequestLabelFailing", { number: pr.number, state, passed, total, failed: failedRows })
        : t("header.pullRequestLabelChecks", { number: pr.number, state, passed, total });
  const number = `#${pr.number}${pr.state === "open" ? "" : ` ${state}`}`;
  const badge = hasFailed
    ? `${number} ✕${failedRows || ""} · ${passed}/${total}`
    : hasPending
      ? `${number} …${pendingRows || ""} · ${passed}/${total}`
      : total > 0
        ? `${number} ✓${passed}/${total}`
        : number;
  const checkState = hasFailed
    ? failedRows === 0 || total === 0
      ? t("rail.checksFailing")
      : undefined
    : hasPending
      ? t("rail.checksPending")
      : undefined;
  return {
    label: checkState ? `${label} · ${checkState}` : label,
    badge: onBase > 0 ? `${badge} · ${onBase} ${t("header.prCheckOnBase")}` : badge,
  };
}
export interface HeaderOperationAction {
  label: string;
  enabled: boolean;
  run(): void;
}
export interface PullRequestOps {
  identity: string;
  merging: Merging;
  start?: HeaderOperationAction;
  confirm?: HeaderOperationAction;
  cancel?: HeaderOperationAction;
  messages: string[];
  question?: string;
}
export function mergeView(pr: HeaderPullRequest, state: Merging, t: Translate) {
  return {
    visible: state.step !== "idle" || readyToMerge(pr),
    confirming: state.step === "confirm" || state.step === "merging",
    question: t("header.prMergeQuestion", { number: pr.number }),
    start: t("header.prMerge"),
    confirm: t(state.step === "merging" ? "header.prMerging" : "header.prMergeConfirm"),
    cancel: t("header.prMergeCancel"),
    message:
      state.step === "failed"
        ? state.message
        : state.step === "merged" || state.step === "queued"
          ? t(state.step === "merged" ? "header.prMerged" : "header.prMergeQueued")
          : undefined,
  };
}
export function runPullRequestMerge(
  pr: HeaderPullRequest,
  set: (state: Merging) => void,
  merge: (pr: { number: number; url: string }) => Promise<MergeResult>,
  t: Translate,
) {
  set({ step: "merging" });
  void (async () => {
    try {
      const result = await merge({ number: pr.number, url: pr.url });
      set({ step: result.queued ? "queued" : "merged" });
    } catch (error) {
      set({
        step: "failed",
        message: error instanceof Error && error.message ? error.message : t("header.prMergeFailed"),
      });
    }
  })();
}
/// Each target generation owns its completions, including A → B → A. Synchronous clicks see
/// pending immediately. DOM/native switches share this operation instead of mounting a new one.
export function usePullRequestOps(
  pr: HeaderPullRequest | undefined,
  merge?: (pr: { number: number; url: string }) => Promise<MergeResult>,
): PullRequestOps {
  const t = useT();
  const [, changed] = useState(0);
  const alive = useRef(true);
  const identity = pr ? JSON.stringify([pr.url, pr.number]) : "";
  const live = useRef({ identity, state: { step: "idle" } as Merging });
  if (live.current.identity !== identity) live.current = { identity, state: { step: "idle" } };
  const target = live.current;
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const set = (state: Merging) => {
    if (!alive.current || live.current !== target) return;
    target.state = state;
    changed((n) => n + 1);
  };
  const state = target.state;
  if (!pr || !merge) return { identity, merging: state, messages: [] };
  const view = mergeView(pr, state, t);
  const current = () => alive.current && live.current === target;
  return {
    identity,
    merging: state,
    messages: view.message ? [view.message] : [],
    ...(view.confirming
      ? {
          question: view.question,
          confirm: {
            label: view.confirm,
            enabled: state.step === "confirm",
            run: () => {
              if (current() && target.state.step === "confirm") runPullRequestMerge(pr, set, merge, t);
            },
          },
          cancel: {
            label: view.cancel,
            enabled: state.step === "confirm",
            run: () => {
              if (current() && target.state.step === "confirm") set({ step: "idle" });
            },
          },
        }
      : view.visible && state.step !== "merged" && state.step !== "queued"
        ? {
            start: {
              label: view.start,
              enabled: true,
              run: () => {
                if (current() && (target.state.step === "idle" || target.state.step === "failed"))
                  set({ step: "confirm" });
              },
            },
          }
        : {}),
  };
}
