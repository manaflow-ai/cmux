import React, { useRef, useState, type Dispatch, type SetStateAction } from "react";
import {
  CMUX_PASS_THROUGH,
  composerCommand,
  harnessTakesToo,
  type CmuxCommand,
  type CmuxCommandResult,
} from "../cmuxCommands";
import { useT } from "../i18n";
import { withoutInlineTokens, type ComposerAttachment } from "../attachments";

export type NewTabCommandActions = {
  importError?: string | undefined;
  importSandboxed?: boolean;
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
    cancelHeldSend(): void;
  },
) {
  const t = useT();
  const [refusal, setRefusal] = useState<{ text: string; message: string }>();
  const [fileError, setFileError] = useState<string>();
  const importInput = useRef<HTMLInputElement>(null);
  const pending = useRef(false);
  const currentText = useRef(text);
  currentText.current = text;
  const intercept = (prompt: string, harness?: string, attachmentCount = 0, ownedOnly = false): boolean => {
    // Inline chips mark positions, not command words; pending chips count too.
    const words = withoutInlineTokens(
      prompt,
      (id) => intake.attachments.some((chip) => chip.id === id) || intake.pending.some((chip) => chip.id === id),
    );
    const command = composerCommand(words, harness, attachmentCount);
    if (!command) return false;
    const refuse = (message: string) => setRefusal({ text, message });
    if (command.kind === "cliOnly") {
      if (ownedOnly) return false;
      refuse(t(command.key, { command: command.name }));
      return true;
    }
    if (pending.current) return true;
    const consumeAttachments = () => {
      // This command supersedes any earlier Return still waiting for those files.
      intake.cancelHeldSend();
      // Consume only this dispatch's chips. A later paste survives an asynchronous command.
      const went = new Set(intake.attachments.map((attachment) => attachment.id));
      intake.setAttachments((current) => current.filter((attachment) => !went.has(attachment.id)));
      for (const attachment of intake.pending) intake.cancel(attachment.id);
    };
    const clear = () => {
      consumeAttachments();
      setText((current) => (current === text ? "" : current));
      setRefusal(undefined);
    };
    if (command.command.action === "import") {
      if (actions.importSandboxed) refuse(t("composer.cmuxImportSandbox"));
      else if (!actions.onImportFile) refuse(t("composer.cmuxUnavailable"));
      else {
        setFileError(undefined);
        importInput.current?.click();
        clear();
      }
      return true;
    }
    if (!actions.onCmuxCommand && harnessTakesToo(command.command)) return false;
    if (!actions.onCmuxCommand) {
      refuse(t("composer.cmuxUnavailable"));
      return true;
    }
    const accepted = actions.onCmuxCommand(command.command, command.args);
    // A passthrough command is not intercepted: it goes on as a normal prompt.
    if (accepted === CMUX_PASS_THROUGH) return false;
    if (typeof accepted === "string") refuse(accepted);
    else if (accepted instanceof Promise) {
      // Consume files immediately, but retain the question until the host accepts it.
      consumeAttachments();
      setRefusal(undefined);
      pending.current = true;
      void accepted.then(
        () => {
          pending.current = false;
          setText((current) => (current === text ? "" : current));
        },
        () => {
          pending.current = false;
          setRefusal({ text: currentText.current, message: t("composer.cmuxUnavailable") });
        },
      );
    } else if (accepted === false) refuse(t("composer.cmuxUnavailable"));
    else clear();
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
        // The selected mode can change while the native picker is open.
        if (actions.importSandboxed) {
          setFileError(t("composer.cmuxImportSandbox"));
          return;
        }
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
