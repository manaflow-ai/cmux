import { useCallback, useEffect, useMemo, useState } from "react";
import type { CloudEnvironment } from "../../pages/cloud/environmentModel";
import { translate as t } from "./i18n";
import { postNative } from "./native";
import { openCloudEnvironment } from "./cloudEnvironment";
import {
  AUTO_ENVIRONMENT,
  autoEditEnvironment,
  autoEnvironment,
  cloudStartEnvironment,
  recentEnvironments,
  rememberEnvironment,
  type CloudEnvironmentControl,
  type CloudEnvironmentPick,
} from "./cloudEnvironmentChoice";

/// The chip's live control for a new chat's strip: the account's environments
/// (`cloud.environment.list`), this folder's recent picks, and the chat's pick, which its Cloud send
/// names (App.tsx `sendToCloud`). The pick is the chat's own (`held`, kept with its run mode in
/// App.tsx); a composer given none keeps its own, which goes with it. Undefined while `enabled` is
/// off (CLOUD_ENVIRONMENTS_ENABLED, or no new chat): nothing is read then.
export function useCloudEnvironmentControl(
  enabled: boolean,
  folder: string | undefined,
  repo: string | undefined,
  held?: CloudEnvironmentPick,
): CloudEnvironmentControl | undefined {
  const [environments, setEnvironments] = useState<readonly CloudEnvironment[]>([]);
  const [own, setOwn] = useState(AUTO_ENVIRONMENT);
  const current = held?.current ?? own;
  const setPick = held?.onPick ?? setOwn;
  const load = useCallback(() => {
    postNative<unknown>("cloud.environment.list").then(
      (list) => {
        if (Array.isArray(list)) setEnvironments(list as CloudEnvironment[]);
      },
      // Signed out, Cloud off or offline: Auto and the actions still show; the list stays as it was.
      () => undefined,
    );
  }, []);
  useEffect(() => {
    if (enabled) load();
  }, [enabled, load]);
  if (!enabled) return undefined;
  const recent = recentEnvironments(folder, environments);
  const named = environments.find((environment) => environment.id === current);
  const auto = autoEnvironment(environments);
  // Remembered first, so the render the new pick causes reads this folder's new order.
  const pick = (id: string) => {
    rememberEnvironment(folder, id);
    setPick(id);
  };
  return {
    recent,
    current,
    ...(named ? { currentName: named.name } : {}),
    ...(auto ? { auto } : {}),
    onPick: pick,
    onNew: () =>
      openCloudEnvironment({
        create: { name: folderName(folder) ?? t("composer.envNewName") },
        section: "script",
        ...(repo ? { repo } : {}),
        onCreated: (environment) => {
          setEnvironments((list) => [...list.filter((kept) => kept.id !== environment.id), environment]);
          pick(environment.id);
        },
      }),
    onEdit: (id) => {
      // Auto's (no id) is the Default it runs in: the team's in a team's context, else the personal one.
      const target = id ?? autoEditEnvironment(environments);
      openCloudEnvironment({
        ...(target ? { environmentId: target } : {}),
        section: id ? "overview" : "script",
        ...(repo ? { repo } : {}),
      });
    },
    onNewMachine: (environment) => {
      void postNative("action.run", { id: "newCloudMachine", ...(environment ? { environment } : {}) }).catch(
        () => undefined,
      );
    },
    onOpen: load,
  };
}

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

/// A new environment's name: the project's folder name.
function folderName(folder: string | undefined): string | undefined {
  const name = folder?.replace(/\/+$/, "").split("/").pop();
  return name || undefined;
}
