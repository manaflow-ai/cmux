// The Import Cookies card at the bottom of a browser page (the native host is CmuxNextBrowser's
// BrowserCookieImportCard, which floats it on the window's overlay and draws its glass). It draws
// the host's lines on the type scale and one aligned row of answers: Don't Show Again as a quiet
// link, Not Now and Import at the same height. It never takes focus, so Return and Escape stay the
// page's; every answer closes it (the host does).
import { Button } from "../../ui/Button";
import "../../ui/popupSurface.css";
import type { CookieImportCardModel, CookieImportChoice, CookieImportLook } from "./model";
import "./cookieImport.css";

export type CookieImportCardProps = {
  model: CookieImportCardModel;
  onChoice: (choice: CookieImportChoice) => void;
  look?: CookieImportLook;
  /** Draws its own glass card. Off in the app, where the native card is the glass. */
  glass?: boolean;
};

export function CookieImportCard({ model, onChoice, look = "split", glass = true }: CookieImportCardProps) {
  const never = model.neverTitle ? (
    <Button variant="ghost" size="sm" className="ci-never" onClick={() => onChoice("never")}>
      {model.neverTitle}
    </Button>
  ) : null;
  const answers = (
    <span className="ci-answers">
      <Button variant="subtle" size="sm" className="ci-answer" onClick={() => onChoice("notNow")}>
        {model.notNowTitle}
      </Button>
      <Button variant="solid" size="sm" className="ci-answer" onClick={() => onChoice("import")}>
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
