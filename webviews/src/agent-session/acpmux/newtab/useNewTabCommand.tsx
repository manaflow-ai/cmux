import React, { useRef, useState, type Dispatch, type SetStateAction } from "react";
import { composerCommand, type CmuxCommand, type CmuxCommandResult } from "../cmuxCommands";
import { useT } from "../i18n";

export type NewTabCommandActions = {
  onCmuxCommand?(command: CmuxCommand, args?: string): CmuxCommandResult;
  onImportFile?(file: File): void | Promise<void>;
};

/** Both New Tab templates consume owned commands before omnibar or chat dispatch. */
export function useNewTabCommand(
  text: string,
  setText: Dispatch<SetStateAction<string>>,
  actions: NewTabCommandActions,
) {
  const t = useT();
  const [refusal, setRefusal] = useState<{ text: string; message: string }>();
  const importInput = useRef<HTMLInputElement>(null);
  const pending = useRef(false);
  const intercept = (prompt: string, harness?: string, attachmentCount = 0): boolean => {
    const command = composerCommand(prompt, harness, attachmentCount);
    if (!command) return false;
    const refuse = (message: string) => setRefusal({ text, message });
    if (command.kind === "cliOnly") {
      refuse(t(command.key, { command: command.name }));
      return true;
    }
    if (pending.current) return true;
    const clear = () => {
      setText((current) => (current === text ? "" : current));
      setRefusal(undefined);
    };
    if (command.command.action === "import") {
      if (!actions.onImportFile) refuse(t("composer.cmuxUnavailable"));
      else {
        importInput.current?.click();
        clear();
      }
      return true;
    }
    if (!actions.onCmuxCommand) {
      refuse(t("composer.cmuxUnavailable"));
      return true;
    }
    const accepted = actions.onCmuxCommand(command.command, command.args);
    if (typeof accepted === "string") refuse(accepted);
    else if (accepted instanceof Promise) {
      pending.current = true;
      void accepted.then(
        () => {
          pending.current = false;
          clear();
        },
        () => {
          pending.current = false;
        },
      );
    } else if (accepted !== false) clear();
    return true;
  };
  const input = (
    <input
      ref={importInput}
      className="acpmux-import-input"
      type="file"
      accept=".json,.jsonl,.txt,application/json,text/plain"
      tabIndex={-1}
      aria-label="/import"
      hidden
      onChange={(event) => {
        const file = event.currentTarget.files?.[0];
        event.currentTarget.value = "";
        if (file) void actions.onImportFile?.(file);
      }}
    />
  );
  return { intercept, input, error: refusal?.text === text ? refusal.message : undefined };
}
