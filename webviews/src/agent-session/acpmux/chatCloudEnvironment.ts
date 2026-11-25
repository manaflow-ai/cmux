import { useMemo, useState } from "react";
import { useDefaultCloudImage } from "./chatDisplay";
import { AUTO_ENVIRONMENT, cloudStartEnvironment, type CloudEnvironmentPick } from "./cloudEnvironmentChoice";

/// The environment a new chat starts from: its own pick when it made one, else Settings > Cloud >
/// Default Image (`cloud.defaultImage`, chatDisplay.ts `defaultCloudImage`), else Auto.
export function chatEnvironmentPick(own: string | undefined, settingDefault: string | undefined): string {
  return own ?? (settingDefault || AUTO_ENVIRONMENT);
}

/// A new chat's Cloud environment, held per chat (App.tsx, with its run mode): the Default Image setting
/// until the chat picks its own, and the setting again when `chat` changes (a chat starts here, or another
/// new chat shows) and once a Cloud send takes it, so a pick never rides into a later chat's send.
/// `forSend` is what that send names (`cloudStartEnvironment`: the start's own, else the pick; none on
/// Auto or with the flag off).
export function useChatCloudEnvironment(chat: string): {
  pick: CloudEnvironmentPick;
  forSend(explicit: string | undefined): string | undefined;
} {
  const settingDefault = useDefaultCloudImage();
  // `own` is the chat's explicit pick; undefined follows the setting.
  const [held, setHeld] = useState<{ chat: string; own: string | undefined }>({ chat, own: undefined });
  // Another chat: back to the setting in this render, before anything reads the old chat's pick.
  const own = held.chat === chat ? held.own : undefined;
  if (held.chat !== chat) setHeld({ chat, own: undefined });
  const current = chatEnvironmentPick(own, settingDefault);
  // The same pick object while the chat and its pick stay: the composer takes it in its run mode
  // rows, and a new object each render drew the composer again on every pane event.
  const pick = useMemo<CloudEnvironmentPick>(
    () => ({ current, onPick: (id) => setHeld({ chat, own: id }) }),
    [chat, current],
  );
  return {
    pick,
    forSend: (explicit) => {
      const environment = cloudStartEnvironment(explicit, current);
      setHeld({ chat, own: undefined });
      return environment;
    },
  };
}
