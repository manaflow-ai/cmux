import { useHeaderState } from "../header/headerState";

/// Side sessions (`/btw <question>` opens a read-only side session beside the chat): the one gate
/// every entry point reads. It is on by default, with `agentPane.debug.sideSessions` as an explicit
/// kill switch; the app sends it as `sideSessions` in the chat's header state.
export function useSideSessions(): boolean {
  return useHeaderState().sideSessions;
}
