// The Import Cookies card at the bottom of a browser page (the native host is CmuxNextBrowser's
// BrowserCookieImportCard, which floats it on the window's overlay and draws its glass). It draws
// the host's lines on the type scale and one aligned row of answers: Don't Show Again as a quiet
// link, Not Now and Import at the same height. It never takes focus, so Return and Escape stay the
// page's; every answer closes it (the host does).
import { Checkbox } from "@base-ui/react/checkbox";
import { useState } from "react";
import { Button } from "../../ui/Button";
import "../../ui/popupSurface.css";
import type { CookieImportCardModel, CookieImportCommand, CookieImportLook } from "./model";
import "./cookieImport.css";

export type CookieImportCardProps = {
  model: CookieImportCardModel;
  /** The answer; Import carries the Keep in sync choice when the card shows the checkbox. */
  onChoice: (command: CookieImportCommand) => void;
  look?: CookieImportLook;
  /** Draws its own glass card. Off in the app, where the native card is the glass. */
  glass?: boolean;
};

export function CookieImportCard({ model, onChoice, look = "split", glass = true }: CookieImportCardProps) {
  const [keepInSync, setKeepInSync] = useState(model.keepInSync !== false);
  const keep = model.keepInSyncTitle ? (
    <label className="ci-keep">
      <Checkbox.Root className="ci-keep-box" checked={keepInSync} onCheckedChange={(next) => setKeepInSync(next)}>
        <Checkbox.Indicator className="ci-keep-mark">
          <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
            <path
              d="M2.5 6.2 4.9 8.6 9.5 3.6"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </Checkbox.Indicator>
      </Checkbox.Root>
      <span>{model.keepInSyncTitle}</span>
    </label>
  ) : null;
  const never = model.neverTitle ? (
    <Button variant="ghost" size="sm" className="ci-never" onClick={() => onChoice({ type: "never" })}>
      {model.neverTitle}
    </Button>
  ) : null;
  const answers = (
    <span className="ci-answers">
      <Button variant="subtle" size="sm" className="ci-answer" onClick={() => onChoice({ type: "notNow" })}>
        {model.notNowTitle}
      </Button>
      <Button
        variant="solid"
        size="sm"
        className="ci-answer"
        onClick={() => onChoice(model.keepInSyncTitle ? { type: "import", keepInSync } : { type: "import" })}
      >
        {model.importTitle}
      </Button>
    </span>
  );
  return (
    <section
      className={glass ? "ci-card ui-popup ui-glass" : "ci-card"}
      data-look={look}
      data-icon={model.icon ? true : undefined}
      aria-label={model.title}
    >
      {model.icon ? <img className="ci-icon" src={model.icon} alt="" draggable={false} /> : null}
      <div className="ci-text">
        <span className="ci-title">{model.title}</span>
        {model.detail ? <span className="ci-detail">{model.detail}</span> : null}
        {keep}
        {look === "inline" ? never : null}
      </div>
      {look === "inline" ? (
        answers
      ) : (
        <div className="ci-row">
          {look === "split" ? never : null}
          <span className="ci-spacer" />
          {look === "trailing" ? never : null}
          {answers}
        </div>
      )}
    </section>
  );
}
