import { useState } from "react";
import { actionRefusal } from "../actionRefusal";
import { useT } from "../i18n";
import { postNative } from "../native";

/** Both Session Info renderers send a session-bound intent. Native owns the machine and route. */
export function useScreenSharing(session: string | undefined) {
  const t = useT();
  const [refusal, setRefusal] = useState<{ session: string; text: string }>();
  return {
    note: refusal?.session === session ? refusal?.text : undefined,
    run: session
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
