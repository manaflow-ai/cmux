import { useEffect, useState } from "react";
import { type HostOverload, OVERLOAD_POLL_MS, readHostOverload } from "./overloadNoticeModel";

/// Polls acpmux for this machine's overload verdict while the page is shown.
export function useHostOverload(read: (() => Promise<unknown>) | undefined): HostOverload | undefined {
  const [state, setState] = useState<HostOverload>();
  useEffect(() => {
    if (!read) return;
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
