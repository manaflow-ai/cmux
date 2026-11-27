// Computer Use setup: the helper app's large icon, a heading, a short line (the ready line once
// every grant is on), a card per grant with one trailing control (Done with a check, Allow filled
// only on the next missing row, or nothing), and a footer with the note on why Allow cannot help
// (else the line saying Computer Use runs in its own helper app) on the left and Not Now / Restart /
// Done on the right. Allow and Done share one slot, so a grant landing swaps them in place. When the
// host counts a comeback (a grant landed, or the drag panel's back button closed it), focus returns
// to the primary control. Once the person's Allow got the last grant on (`finished`), the head and
// rows give way to the done view (a green check, "Computer Use Is Ready") and the host closes the
// window by itself.
import { useEffect, useRef } from "react";
import { Button } from "../../ui/Button";
import { DialogButton } from "../../ui/DialogButton";
import { StableLabel } from "../../ui/StableLabel";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { Check } from "../../agent-session/acpmux/conversation/icons";
import { OPS, type ComputerUseRow, type ComputerUseState } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { computerUseCaptureNote, computerUseLine, computerUseName, computerUseNote } from "./text";

function GrantRow({ row, confirmsCapture }: { row: ComputerUseRow; confirmsCapture: boolean }) {
  const { strings, store } = useOnboarding();
  const name = computerUseName(strings, row.pane);
  const allows = row.control === "allow" || row.control === "allowPrimary";
  const done = row.control === "done";
  const allow = strings.t("onboarding.computerUse.allow");
  const doneLabel = strings.t("onboarding.computerUse.done");
  // Screenshots just allowed here: macOS asks once more, so its note takes the row's line.
  const capture = computerUseCaptureNote(strings, row.pane, confirmsCapture);
  return (
    <li className="onb-grant" data-pane={row.pane} data-control={row.control}>
      <HostIcon image={row.icon} className="onb-grant-icon" />
      <span className="onb-grant-names">
        <span className="onb-grant-name">{name}</span>
        <span className="onb-grant-line" data-confirm={capture ? "" : undefined}>
          {capture ? capture.confirm : computerUseLine(strings, row.pane)}
        </span>
        {capture && <span className="onb-grant-detail">{capture.detail}</span>}
      </span>
      <span className="onb-slot onb-grant-control">
        <Button
          variant={row.control === "allowPrimary" ? "solid" : "subtle"}
          className="onb-capsule"
          data-shown={allows ? "" : undefined}
          data-primary-control={row.control === "allowPrimary" ? "" : undefined}
          aria-hidden={allows ? undefined : true}
          tabIndex={allows ? undefined : -1}
          aria-label={strings.format("onboarding.computerUse.allow.named", name)}
          onClick={() => {
            if (allows) store.call(OPS.allow, { pane: row.pane });
          }}
        >
          <StableLabel label={allow} alternatives={[allow, doneLabel]} />
        </Button>
        <span className="onb-grant-done" data-shown={done ? "" : undefined} aria-hidden={done ? undefined : true}>
          <span>{doneLabel}</span>
          <Check size={12} />
        </span>
      </span>
    </li>
  );
}

/** The done view: a green check, the title and the line; the window closes by itself. */
function FinishedView() {
  const { strings } = useOnboarding();
  return (
    <div className="onb-cu-finished" aria-live="polite">
      <StatusGlyph name="done" size={64} className="onb-cu-finished-mark" />
      <h1 className="onb-title">{strings.t("onboarding.computerUse.done.title")}</h1>
      <p className="onb-sentence">{strings.t("onboarding.computerUse.done.line")}</p>
    </div>
  );
}

export function ComputerUseStep({ computerUse }: { computerUse: ComputerUseState }) {
  const { strings, store } = useOnboarding();
  const root = useRef<HTMLDivElement>(null);
  const seen = useRef(computerUse.comebacks);
  useEffect(() => {
    if (computerUse.comebacks === seen.current) return;
    seen.current = computerUse.comebacks;
    const primary = root.current?.querySelector<HTMLElement>("[data-primary-control]:not([aria-hidden])");
    primary?.focus({ preventScroll: true });
  }, [computerUse.comebacks]);
  const note = computerUseNote(strings, computerUse.note);
  const done = strings.t("onboarding.computerUse.done");
  const restart = strings.t("onboarding.computerUse.restart");
  return (
    <div className="onb-cu" ref={root} data-finished={computerUse.finished ? "" : undefined}>
      {computerUse.finished ? (
        <FinishedView />
      ) : (
        <>
          <div className="onb-cu-head">
            <HostIcon image={computerUse.helperIcon} className="onb-cu-helper" />
            <h1 className="onb-title">{strings.t("onboarding.computerUse.heading")}</h1>
            <p className="onb-sentence">
              {computerUse.allGranted
                ? strings.t("onboarding.computerUse.ready")
                : strings.t("onboarding.computerUse.body")}
            </p>
          </div>
          <ul className="onb-grants">
            {computerUse.rows.map((row) => (
              <GrantRow key={row.pane} row={row} confirmsCapture={computerUse.confirmsCapture} />
            ))}
          </ul>
        </>
      )}
      <footer className="onb-cu-footer">
        <div className="onb-cu-aside">
          <output className="onb-cu-note" aria-live="polite">
            {note ?? ""}
          </output>
          {note == null && !computerUse.finished && (
            <p className="onb-cu-footnote">{strings.t("onboarding.computerUse.footnote")}</p>
          )}
        </div>
        <div className="onb-footer-buttons">
          {!computerUse.allGranted && !computerUse.showsRestart && (
            <DialogButton
              dialogKey="escape"
              className="ui-button ui-btn"
              data-variant="ghost"
              data-size="md"
              onClick={() => store.call(OPS.skip)}
            >
              {strings.t("onboarding.computerUse.notNow")}
            </DialogButton>
          )}
          {(computerUse.showsRestart || computerUse.allGranted) && (
            <DialogButton
              dialogKey="return"
              className="ui-button ui-btn onb-capsule"
              data-variant="solid"
              data-size="md"
              data-primary-control=""
              onClick={() => store.call(computerUse.showsRestart ? OPS.restart : OPS.next)}
            >
              <StableLabel label={computerUse.showsRestart ? restart : done} alternatives={[restart, done]} />
            </DialogButton>
          )}
        </div>
      </footer>
    </div>
  );
}
