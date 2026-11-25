import { useMemo, useState } from "react";
import { AUTO_ENVIRONMENT, cloudStartEnvironment, type CloudEnvironmentPick } from "./cloudEnvironmentChoice";

/// A new chat's Cloud environment, held per chat (App.tsx, with its run mode): Auto until picked, and
/// Auto again when `chat` changes (a chat starts here, or another new chat shows) and once a Cloud
/// send takes it, so a pick never rides into a later chat's send. `forSend` is what that send names
/// (`cloudStartEnvironment`: the start's own, else the pick; none on Auto or with the flag off).
export function useChatCloudEnvironment(chat: string): {
  pick: CloudEnvironmentPick;
  forSend(explicit: string | undefined): string | undefined;
} {
  const [held, setHeld] = useState({ chat, current: AUTO_ENVIRONMENT });
  // Another chat: back to Auto in this render, before anything reads the old chat's pick.
  const current = held.chat === chat ? held.current : AUTO_ENVIRONMENT;
  if (held.chat !== chat) setHeld({ chat, current: AUTO_ENVIRONMENT });
  // The same pick object while the chat and its pick stay: the composer takes it in its run mode
  // rows, and a new object each render drew the composer again on every pane event.
  const pick = useMemo<CloudEnvironmentPick>(
    () => ({ current, onPick: (id) => setHeld({ chat, current: id }) }),
    [chat, current],
  );
  return {
    pick,
    forSend: (explicit) => {
      const environment = cloudStartEnvironment(explicit, current);
      setHeld({ chat, current: AUTO_ENVIRONMENT });
      return environment;
    },
  };
}
