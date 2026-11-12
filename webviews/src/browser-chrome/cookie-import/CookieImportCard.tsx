// The Import Cookies card at the bottom of a browser page (the native host is CmuxNextBrowser's
// BrowserCookieImportCard, which floats it on the window's overlay and draws the toast surface's
// glass under it). Leo, 2026-11-08: "i dont like this. 1. looks bad. 2. not glass. 3. talks about
// too much irrelevant shit". It is a toast now: the browser's icon, one line, and the toast's
// clear-text answers. Lawrence 2026-11-09 (msg 26162, "ugly flat gray, washed-out text"): it draws in the
// dialog card's grammar now (the overlay dialog's buttons): the line in the title's weight, Don't Show
// Again quiet text, Not Now a gray button and Import the filled primary, every answer labelled. Keep in
// sync is Settings > Browser > Import (`browser.import.cookieSync`, on by default), not a line here.
// It never takes focus, so Return and Escape stay the page's; every answer closes it (the host does).
import { Button } from "../../ui/Button";
import "../../ui/glass/glass.css";
import type { CookieImportCardModel, CookieImportCommand, CookieImportLook } from "./model";
import "./cookieImport.css";

export type CookieImportCardProps = {
  model: CookieImportCardModel;
  onChoice: (command: CookieImportCommand) => void;
  look?: CookieImportLook;
  /** Draws its own glass. Off in the app, where the native card is the glass. */
  glass?: boolean;
};

export function CookieImportCard({ model, onChoice, look = "toast", glass = true }: CookieImportCardProps) {
  const choose = (type: CookieImportCommand["type"]) => () => onChoice({ type });
  const icon = model.icon ? <img className="ci-icon" src={model.icon} alt="" draggable={false} /> : null;
  const title = <span className="ci-title">{model.title}</span>;
  const className = glass ? "ci-card ui-glass" : "ci-card";
  if (look === "toast") {
    return (
      <section
        className={className}
        data-look={look}
        data-native-glass={glass ? undefined : true}
        aria-label={model.title}
      >
        {icon}
        {title}
        <span className="ci-toast-answers">
          {model.neverTitle ? (
            <button type="button" className="ci-action" data-role="quiet" onClick={choose("never")}>
              {model.neverTitle}
            </button>
          ) : null}
          <button type="button" className="ci-action" data-role="cancel" onClick={choose("notNow")}>
            {model.notNowTitle}
          </button>
          <button type="button" className="ci-action" data-role="default" onClick={choose("import")}>
            {model.importTitle}
          </button>
        </span>
      </section>
    );
  }
  const never = model.neverTitle ? (
    <Button variant="ghost" size="sm" className="ci-never" onClick={choose("never")}>
      {model.neverTitle}
    </Button>
  ) : null;
  const answers = (
    <span className="ci-answers">
      <Button variant="subtle" size="sm" className="ci-answer" onClick={choose("notNow")}>
        {model.notNowTitle}
      </Button>
      <Button variant="solid" size="sm" className="ci-answer" onClick={choose("import")}>
        {model.importTitle}
      </Button>
    </span>
  );
  return (
    <section
      className={className}
      data-look={look}
      data-native-glass={glass ? undefined : true}
      aria-label={model.title}
    >
      {icon}
      {title}
      {look === "stacked" ? (
        <div className="ci-row">
          {never}
          <span className="ci-spacer" />
          {answers}
        </div>
      ) : (
        <>
          {never}
          {answers}
        </>
      )}
    </section>
  );
}
