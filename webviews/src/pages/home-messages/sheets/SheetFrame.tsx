// The frame of the Messages page's sheets (Invite, Invite to Team, New Chief, Message Requests),
// as HomeSheetController drew it: a title, the sheet's content, a status line that says why an
// action did not finish, then Cancel (⎋) and the default button (↩). `useSheetRun` disables the
// buttons while an action runs; an opened conversation or a sent invite closes the sheet. The
// status line keeps its line while empty, so a refusal never moves the buttons.
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import type { Strings } from "../../shared/i18n";
import { DialogButton } from "../../../ui/DialogButton";
import { FormDialog } from "../../home-channels/FormDialog";
import { composeCloses, composeMessage, type ComposeOutcome } from "./model";
import "./sheets.css";

/** The running action, its status line, and the finish that closes the sheet once. */
export function useSheetRun(strings: Strings, onFinish: (conversation: string | null) => void) {
  const [running, setRunning] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const live = useRef(true);
  const finished = useRef(false);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const finish = useCallback(
    (conversation: string | null) => {
      if (finished.current) return;
      finished.current = true;
      onFinish(conversation);
    },
    [onFinish],
  );
  const run = useCallback(
    (action: () => Promise<ComposeOutcome>) => {
      if (running) return;
      setRunning(true);
      setStatus(null);
      void action().then((outcome) => {
        if (!live.current) return;
        setRunning(false);
        const close = composeCloses(outcome);
        if (close.closes) finish(close.conversation ?? null);
        else setStatus(composeMessage(outcome, strings));
      });
    },
    [finish, running, strings],
  );
  return { running, status, setStatus, setRunning, run, finish };
}

export interface SheetFrameProps {
  strings: Strings;
  title: string;
  /** The default button's title. */
  primary: string;
  canSubmit: boolean;
  running: boolean;
  status: string | null;
  onSubmit(): void;
  /** Cancel, Escape or a press outside: nothing to show. */
  onCancel(): void;
  /** A test id for the sheet (`cmux.home.<sheet>`). */
  id: string;
  children?: ReactNode;
}

export function SheetFrame({
  strings,
  title,
  primary,
  canSubmit,
  running,
  status,
  onSubmit,
  onCancel,
  id,
  children,
}: SheetFrameProps) {
  const ready = canSubmit && !running;
  return (
    <FormDialog
      title={title}
      onClose={onCancel}
      onSubmit={() => {
        if (ready) onSubmit();
      }}
      busy={running}
      actions={
        <>
          <DialogButton dialogKey="escape" className="hc-text-button" onClick={onCancel}>
            {strings.t("home.compose.cancel")}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            type="submit"
            className="hc-text-button primary"
            disabled={!ready}
            data-testid="cmux.home.sheet.primary"
          >
            {primary}
          </DialogButton>
        </>
      }
    >
      <div className="hm-sheet" data-testid={id}>
        {children}
        <output className="hm-sheet-status" aria-live="polite" data-testid="cmux.home.sheet.status">
          {status ?? ""}
        </output>
      </div>
    </FormDialog>
  );
}
