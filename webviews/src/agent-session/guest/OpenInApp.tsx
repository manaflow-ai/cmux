// The guest page's open-in-app banner (appLink.ts): the link opens in the cmux app when it is installed,
// the way Zoom, Figma and Slack hand a link to their app. The page asks the app once, at load. The banner
// floats over the guest page, which mounts at once beneath it (its join card and whoami never wait on the
// attempt, and nothing shifts when the banner goes); when the app takes the link it stays with "Continue in
// browser", and with no app it goes by itself.
import "./guest.css";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { useT } from "../acpmux/i18n";
import { APP_OPEN_WAIT_MS, type AppOpenWindow, tryOpenApp } from "./appLink";

export type OpenInAppProps = {
  /** The app URL (`<scheme>://share?link=...#<secret>`). */
  appUrl: string;
  /** The visitor goes on in the browser (or no app took the link): the banner goes. */
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
    const controller = new AbortController();
    void tryOpenApp(win ?? (window as unknown as AppOpenWindow), appUrl, waitMs, controller.signal).then((took) => {
      if (controller.signal.aborted) return;
      if (took) setOpened(true);
      else continued.current();
    });
    return () => controller.abort();
  }, [appUrl, win, waitMs]);
  return (
    <output className="guest-app" data-testid="guest-open-in-app">
      <span className="guest-app__title">{t(opened ? "guest.app.opened" : "guest.app.opening")}</span>
      <a className="guest-app__open" href={appUrl}>
        {t("guest.app.open")}
      </a>
      <button className="guest-app__browser" type="button" onClick={() => continued.current()}>
        {t("guest.app.browser")}
      </button>
    </output>
  );
}

export type WithOpenInAppProps = {
  /** The guest page: mounted at once, whatever the app attempt is doing. */
  children: ReactNode;
  /** The app URL to offer; none offers nothing. */
  appUrl?: string;
  /** The visitor chose the browser, or no app took the link. */
  onChooseBrowser: () => void;
  win?: AppOpenWindow;
  waitMs?: number;
};

/** The guest page with the open-in-app banner over it while the offer stands. */
export function WithOpenInApp({ children, appUrl, onChooseBrowser, win, waitMs }: WithOpenInAppProps) {
  const [offering, setOffering] = useState(appUrl !== undefined);
  return (
    <>
      {children}
      {offering && appUrl ? (
        <OpenInApp
          appUrl={appUrl}
          win={win}
          waitMs={waitMs}
          onContinue={() => {
            onChooseBrowser();
            setOffering(false);
          }}
        />
      ) : null}
    </>
  );
}
