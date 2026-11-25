import { createContext, useContext } from "react";
import type { Translate } from "../i18n";
import type { ToolFailure } from "./toolFailure";

/// True for a call drawn as one step of an opened "Ran N commands", "Read N files" or "Searched N"
/// group (ToolGroupRow.tsx `Step`); a lone call, also one in an opened run, keeps its Exit word and cause.
/// A failed step reads as one plain line, what failed and the word "failed", with no shell
/// wording ("Exit 1") and no cause line under it; the error output waits behind the step's own
/// disclosure, in its Shell block, which says the exit code. The group's head already counts the
/// failure ("1 failed"). Leo said yes (2026-11-02) to a "Scheduled check" whose "Ran 4 commands
/// 1 failed" opened to a raw "(eval):1: ==== not found" line under a step and "Exit 1" at its edge.
export const InStep = createContext(false);

/// Whether this call is a step of an opened group (`InStep`).
export const useInStep = () => useContext(InStep);

/// What happened, in a word: blocked, denied, timed out, Exit 1, failed. A step (`InStep`) says
/// "failed" for a nonzero exit; its Shell block names the code.
export function failureWord(t: Translate, failure: ToolFailure, step = false): string {
  switch (failure.kind) {
    case "hook":
      return t("tools.blockedByHook");
    case "denied":
      return t("tools.denied");
    case "timeout":
      return t("tools.timedOut");
    case "exit":
      return step ? t("tools.failed") : t("tools.exit", { code: failure.exitCode ?? 1 });
    default:
      return t("tools.failed");
  }
}
