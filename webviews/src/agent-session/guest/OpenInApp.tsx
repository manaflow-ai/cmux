// The step before the guest page (appLink.ts): the link opens in the cmux app when it is installed,
// the way Zoom, Figma and Slack hand a link to their app. The page asks the app once, at load; when
// the app takes it, this card stays with "Continue in browser" for a visitor who wants the page
// anyway; with no app it carries on to the guest page by itself.
import "./guest.css";
import { useEffect, useRef, useState } from "react";
import { useT } from "../acpmux/i18n";
import { APP_OPEN_WAIT_MS, type AppOpenWindow, tryOpenApp } from "./appLink";

export type OpenInAppProps = {
  /** The app URL (`<scheme>://share?link=...#<secret>`). */
  appUrl: string;
  /** The visitor goes on in the browser: the guest page. */
  onContinue: () => void;
  /** The window the attempt reads (tests pass a fake); the page's own by default. */
  win?: AppOpenWindow;
  waitMs?: number;
};

export function OpenInApp({ appUrl, onContinue, win, waitMs = APP_OPEN_WAIT_MS }: OpenInAppProps) {
  const t = useT();
  const [opened, setOpened] = useState(false);
  const continued = useRef(onContinue);
  continued.current = onContinue;
  useEffect(() => {
    let live = true;
    void tryOpenApp(win ?? (window as unknown as AppOpenWindow), appUrl, waitMs).then((took) => {
      if (!live) return;
      if (took) setOpened(true);
      else continued.current();
    });
    return () => {
      live = false;
    };
  }, [appUrl, win, waitMs]);
  return (
    <main className="guest-card" data-testid="guest-open-in-app">
      <h1 className="guest-card__title">{t(opened ? "guest.app.opened" : "guest.app.opening")}</h1>
      <div className="guest-join">
        <a className="guest-join__button guest-app__open" href={appUrl}>
          {t("guest.app.open")}
        </a>
        <button className="guest-app__browser" type="button" onClick={() => continued.current()}>
          {t("guest.app.browser")}
        </button>
      </div>
    </main>
  );
}
