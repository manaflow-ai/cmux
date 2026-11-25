import { useEffect, useEffectEvent } from "react";

/// Runs `send` once each time `ready` turns true: a GitHub repository picked with This Mac picked is checked out
/// only when Return asks (cmux#53226), and the prompt Return held goes once that checkout is the chat's folder.
export function useSendAfterCheckout(ready: boolean, send: () => void): void {
  const run = useEffectEvent(send);
  useEffect(() => {
    if (ready) run();
  }, [ready]);
}
