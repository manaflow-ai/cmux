import { useEffect, useState } from "react";
import { useComposerSettings } from "./composerSettings";
import { type HostOverload, OVERLOAD_POLL_MS, readHostOverload } from "./overloadNoticeModel";

/// Polls acpmux for this machine's overload verdict while the page is shown. No `read` (the
/// Developer Tools setting `developerTools.overloadNotice` is off, the default) asks nothing and
/// forgets the last verdict, so the banner goes as soon as the setting does.
export function useHostOverload(read: (() => Promise<unknown>) | undefined): HostOverload | undefined {
  const [state, setState] = useState<HostOverload>();
  useEffect(() => {
    if (!read) {
      setState(undefined);
      return;
    }
    let stopped = false;
    const poll = () => {
      if (typeof document !== "undefined" && document.visibilityState === "hidden") return;
      read().then(
        (value) => !stopped && setState(readHostOverload(value)),
        () => undefined,
      );
    };
    poll();
    const timer = setInterval(poll, OVERLOAD_POLL_MS);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }, [read]);
  return state;
}

/// The chat's overload verdict, asked only while Settings > Advanced > Developer Tools >
/// Overload Warning in Chats (`developerTools.overloadNotice`, the composer event's
/// `showOverloadNotice`) is on. Off by default (https://github.com/manaflow-ai/cmux/issues/56156:
/// "this should not be on default"): `read` is never called and no banner shows.
export function usePaneHostOverload(read: () => Promise<unknown>): HostOverload | undefined {
  const { showOverloadNotice } = useComposerSettings();
  return useHostOverload(showOverloadNotice ? read : undefined);
}
