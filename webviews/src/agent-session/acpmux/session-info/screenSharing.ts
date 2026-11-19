import { useState } from "react";
import { actionRefusal } from "../actionRefusal";
import type { ChatMachine } from "../chatMachine";
import { useT, type StringKey } from "../i18n";
import { postNative } from "../native";

/// What the chat's machine offers (cmuxterm-hq screen-sharing references, "cmux mapping": `Share`
/// only on this Mac, `View screen` for another machine). This Mac shares; a Cloud machine opens its
/// desktop; a machine the app is connected to (its own daemon: a joined Mac or Linux box) views its
/// screen through the device hub (Leo, 2026-11-18: "i should be able to see into any connected mac or
/// linux machine"). Native picks the route from that daemon's authenticated screen identity and says
/// why when it can't (offline, no screen host). A peer's chat (acpmux names a `peer`: no
/// authenticated mapping to its machine) and an unnamed machine draw no action.
export type ScreenSharingKind = "share" | "view";

export function screenSharingKind(
  machine: Pick<ChatMachine, "kind" | "name">,
  peer?: string,
): ScreenSharingKind | undefined {
  if (!machine.name) return undefined;
  if (machine.kind === "local") return "share";
  if (machine.kind === "cloud") return "view";
  return peer ? undefined : "view";
}

export const SCREEN_SHARING_LABELS: Readonly<Record<ScreenSharingKind, StringKey>> = {
  share: "sessionInfo.environment.shareScreen",
  view: "sessionInfo.environment.viewScreen",
};

/** Both Session Info renderers send a session-bound intent. Native owns the machine and route. */
export function useScreenSharing(session: string | undefined, kind: ScreenSharingKind | undefined) {
  const t = useT();
  const [refusal, setRefusal] = useState<{ session: string; text: string }>();
  return {
    kind,
    note: refusal?.session === session ? refusal?.text : undefined,
    run:
      session && kind
        ? () => {
            setRefusal(undefined);
            void postNative("action.run", { id: "session.screenShare", session }).catch((error) =>
              setRefusal({
                session,
                text: actionRefusal(error) ?? t("sessionInfo.environment.screenSharingUnavailable"),
              }),
            );
          }
        : undefined,
  };
}
