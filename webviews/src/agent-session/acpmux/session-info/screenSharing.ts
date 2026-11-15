import { useState } from "react";
import { actionRefusal } from "../actionRefusal";
import type { ChatMachine } from "../chatMachine";
import { useT, type StringKey } from "../i18n";
import { postNative } from "../native";

/// What the chat's machine offers (cmuxterm-hq screen-sharing references, "cmux mapping": `Share`
/// only on this Mac, `View screen` for a remote machine). Only the routes native can open today are
/// offered: this Mac shares, a Cloud machine opens its desktop. An SSH peer (a Mac waiting on its
/// authenticated device mapping, or a Linux box) and an unnamed machine draw no action, so the row
/// never promises what a click would refuse.
export type ScreenSharingKind = "share" | "view";

export function screenSharingKind(machine: Pick<ChatMachine, "kind" | "name">): ScreenSharingKind | undefined {
  if (!machine.name) return undefined;
  if (machine.kind === "local") return "share";
  if (machine.kind === "cloud") return "view";
  return undefined;
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
