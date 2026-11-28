// The model picker with Cloud picked, or in a chat that runs on a Cloud machine (cmux#51731): it
// lists the agents a Cloud machine carries (Claude Code, Codex, OpenCode, pi:
// web/services/vms/images/agents.ts) with their models, and hides this Mac's own harness profiles
// (claude-sr2, a folder's profile), which exist only here. Each is pickable whatever this Mac has: the
// machine carries the binary, and what lets it run is a connection that serves Cloud (Settings > Cloud >
// Models), not this Mac's install or login. Claude and
// Codex both run once their family is connected for Cloud; a send on one that is not gets the Set up
// Cloud card (cloudSetup.ts, `cloud_setup_required`), whose buttons connect it and start the chat again.
// Its last row opens Settings > Cloud, where the person sets up more ways to reach models on Cloud.
// Claude Code and Codex need a connection that serves Cloud: the host says which families have one
// (`cloud.setupState`, CloudSetup.swift `serving`), and a family with none lists as signed out, its
// models not pickable, with a set up button that runs Cloud's own way in (`cloud.setUp` with no start
// key: Set up Claude, Continue with ChatGPT). OpenCode and pi need none, so they are always pickable.
import { useCallback, useEffect, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import type { ModelPickerProps } from "./modelPickerLayout";
import { CLOUD_MACHINE_AGENTS } from "./harnessModes";
import { postNative } from "./native";
import { chatPlace, routeOnOwnCloud } from "./chatMachine";

type Entry = ModelPickerProps["catalog"][number];

/** True when the composer's chat starts on, or runs on, a Cloud machine, or Auto may start it there
 *  (`cloudPicker`: Cloud and Auto share one picker, apart from This Mac's). */
export function pickerOnCloud(snapshot: AcpmuxSnapshot): boolean {
  return (
    snapshot.startsOnCloud === true ||
    (snapshot.cloudPicker === true && (snapshot.summary?.turnCount ?? 0) === 0) ||
    snapshot.summary?.hostKind === "cloud" ||
    routeOnOwnCloud(chatPlace(snapshot))
  );
}

/** The picker's entries for a Cloud machine: only the agents it carries, each pickable, in the given
 *  order. A local install or sign-in says nothing about the machine, so none is marked missing. */
export function cloudPickerEntries(entries: readonly Entry[]): Entry[] {
  return entries
    .filter((entry) => !entry.folder && CLOUD_MACHINE_AGENTS.has(entry.id.toLowerCase()))
    .map((entry) => {
      const { notInstalled: _notInstalled, unavailable: _unavailable, ...rest } = entry;
      return { ...rest, pickable: true };
    });
}

/** Opens Settings > Cloud: the app's Open Settings on its Cloud page (AgentPaneModel+Actions.swift
 *  `settingsActions`), on the person's click. */
export function openCloudSettings(
  post: (method: string, params: Record<string, unknown>) => Promise<unknown> = postNative,
): void {
  void post("action.run", { id: "openSettings" }).catch(() => undefined);
}

/** The families a Cloud chat runs on a connection (CloudSetup.families). */
export type CloudFamily = "claude" | "codex";
/** `cloud.setupState`'s answer: whether each family has a connection serving Cloud now; a family it
 *  does not name (nothing read, an older host) holds nothing back. */
export type CloudFamilies = Partial<Record<CloudFamily, boolean>>;

/** The family a machine agent needs a connection of, if any. */
export function cloudFamilyOf(id: string): CloudFamily | undefined {
  const name = id.toLowerCase();
  return name === "claude" || name === "codex" ? name : undefined;
}

/** The picker's signed-out map on Cloud (ModelPicker `signedOut`): each listed agent whose family has no
 *  connection serving Cloud, keyed by its id; the value names the family for the set up button. */
export function cloudSignedOut(entries: readonly Entry[], families: CloudFamilies): Record<string, string> {
  const out: Record<string, string> = {};
  for (const entry of entries) {
    const family = cloudFamilyOf(entry.id);
    if (family && families[family] === false) out[entry.id] = family;
  }
  return out;
}

/** The way in a set up button runs for `family` (the Set up Cloud card's first button, cloudSetup.ts). */
export function cloudSetUpAction(family: string): "setUpClaude" | "connectChatGPT" {
  return family === "codex" ? "connectChatGPT" : "setUpClaude";
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/** Reads `cloud.setupState`'s families; {} on a failure or an answer without them. */
export async function readCloudFamilies(post: Native = postNative): Promise<CloudFamilies> {
  try {
    const answer = (await post("cloud.setupState", {})) as { families?: Record<string, unknown> } | null;
    const families: CloudFamilies = {};
    for (const family of ["claude", "codex"] as const) {
      const value = answer?.families?.[family];
      if (typeof value === "boolean") families[family] = value;
    }
    return families;
  } catch {
    return {};
  }
}

/** Which families Cloud runs now, read while `onCloud` (and again on `reread`), and the set up button's run:
 *  Cloud's way in for the family on the person's click, then a fresh read. */
export function useCloudFamilies(
  onCloud: boolean,
  post: Native = postNative,
): { families: CloudFamilies; reread(): void; setUp(family: string): void } {
  const [families, setFamilies] = useState<CloudFamilies>({});
  const [reads, setReads] = useState(0);
  useEffect(() => {
    if (!onCloud) return;
    let live = true;
    void readCloudFamilies(post).then((read) => {
      if (live) setFamilies(read);
    });
    return () => {
      live = false;
    };
  }, [onCloud, reads, post]);
  const reread = useCallback(() => setReads((count) => count + 1), []);
  const setUp = useCallback(
    (family: string) => {
      if (family !== "claude" && family !== "codex") return;
      void post("cloud.setUp", { action: cloudSetUpAction(family), family })
        .catch(() => undefined)
        .finally(reread);
    },
    [post, reread],
  );
  return { families: onCloud ? families : {}, reread, setUp };
}
