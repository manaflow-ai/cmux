import React, { useRef, useState, type Dispatch, type SetStateAction } from "react";
import { composerCommand, type CmuxCommand, type CmuxCommandResult } from "../cmuxCommands";
import { useT } from "../i18n";
import type { ComposerAttachment } from "../attachments";

export type NewTabCommandActions = {
  importError?: string | undefined;
  onCmuxCommand?(command: CmuxCommand, args?: string): CmuxCommandResult;
  onImportFile?(file: File): void | Promise<void>;
};

/** Both New Tab templates consume owned commands before omnibar or chat dispatch. */
export function useNewTabCommand(
  text: string,
  setText: Dispatch<SetStateAction<string>>,
  actions: NewTabCommandActions,
  intake: {
    attachments: readonly ComposerAttachment[];
    setAttachments: Dispatch<SetStateAction<ComposerAttachment[]>>;
    pending: readonly { id: string }[];
    cancel(id: string): void;
  },
) {
  const t = useT();
  const [refusal, setRefusal] = useState<{ text: string; message: string }>();
  const [fileError, setFileError] = useState<string>();
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
      // Consume only this dispatch's chips. A later paste survives an asynchronous command.
      const went = new Set(intake.attachments.map((attachment) => attachment.id));
      intake.setAttachments((current) => current.filter((attachment) => !went.has(attachment.id)));
      for (const attachment of intake.pending) intake.cancel(attachment.id);
      setText((current) => (current === text ? "" : current));
      setRefusal(undefined);
    };
    if (command.command.action === "import") {
      if (!actions.onImportFile) refuse(t("composer.cmuxUnavailable"));
      else {
        setFileError(undefined);
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
      onChange={async (event) => {
        const file = event.currentTarget.files?.[0];
        event.currentTarget.value = "";
        if (!file) return;
        setFileError(undefined);
        try {
          await actions.onImportFile?.(file);
        } catch (error) {
          setFileError(error instanceof Error ? error.message : String(error));
        }
      }}
    />
  );
  return {
    intercept,
    input,
    error: (refusal?.text === text ? refusal.message : undefined) ?? fileError ?? actions.importError,
  };
}
