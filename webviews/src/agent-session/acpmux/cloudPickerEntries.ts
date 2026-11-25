// The model picker with Cloud picked, or in a chat that runs on a Cloud machine (issue #51731): it
// lists the agents a Cloud machine carries (Claude Code, Codex, OpenCode, pi:
// web/services/vms/images/agents.ts) with their models, whether or not this Mac has them installed,
// and hides this Mac's own harness profiles (claude-sr2, a folder's profile), which exist only here.
// Its last row opens Settings > Cloud, where the person sets up more ways to reach models on Cloud.
import { linkScheme } from "./links";
import type { AcpmuxSnapshot } from "./model";
import type { ModelPickerProps } from "./modelPickerLayout";
import { CLOUD_MACHINE_AGENTS } from "./harnessModes";

type Entry = ModelPickerProps["catalog"][number];

/** True when the composer's chat starts on, or runs on, a Cloud machine. */
export function pickerOnCloud(snapshot: AcpmuxSnapshot): boolean {
  return (
    snapshot.startsOnCloud === true ||
    snapshot.summary?.hostKind === "cloud" ||
    (snapshot.origin === "remote" && snapshot.ownerCloud === true)
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

/** `<scheme>://settings/cloud`: Settings > Cloud (DeepLink+AppLink.swift), or undefined before the
 *  host sent its scheme. */
export function cloudSettingsLink(scheme = linkScheme()): string | undefined {
  return scheme ? `${scheme}://settings/cloud` : undefined;
}

/** Opens Settings > Cloud through the host's link path, as an app link in a reply does. */
export function openCloudSettings(doc: Document = document): void {
  const href = cloudSettingsLink();
  if (!href) return;
  const anchor = doc.createElement("a");
  anchor.href = href;
  anchor.click();
}
