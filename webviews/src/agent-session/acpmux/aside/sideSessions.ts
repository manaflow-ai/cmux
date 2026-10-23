import { useHeaderState } from "../header/headerState";

/// Side sessions (`/btw <question>` opens a read-only side session beside the chat): the one gate
/// every entry point reads. It is Debug Settings' Side sessions (/btw) (`agentPane.debug.sideSessions`, off by
/// default), which the app sends as `sideSessions` in the chat's header state; absent means off.
export function useSideSessions(): boolean {
  return useHeaderState().sideSessions;
}
