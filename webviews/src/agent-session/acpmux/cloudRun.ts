/// Cloud as where a new chat runs (Labs, leo-workspace design/cloud-work-mode.md): the environment
/// picker's Cloud row (EnvironmentPicker `runMode` "cloud") makes the chat's first send a
/// `cloud.startChat` to the host (AgentPaneCloudStart). The host takes a Cloud machine sized for
/// the chat, copies the chat's folder there and opens the chat there with this prompt; this tab,
/// which never started a chat, then closes. Nothing asks for a machine, a size or an environment.
/// The host shows the progress and any failure as its own toast, and the chat shows them under the
/// message (CloudStartView, cloudStartProgress.ts); the prompt stays in the composer until the chat
/// opens on the machine.

import { isAgentHome } from "./sessionList";
import { pickFolder } from "./startFolder";

/// What the page hands the host. `home`: the chat has no project folder on this Mac, so nothing is
/// copied and the chat starts in the machine's own home folder (cloudStartFolder).
export type CloudStart = { task: string; cwd?: string; home?: boolean; harness?: string; model?: string };

/// Which folder a Cloud chat starts in: the chat's project on this Mac, copied to the machine, when
/// it has one; else the machine's home folder, with nothing copied (a chat in no project, or one
/// whose folder is home or above it, which is never copied). Leo, 2026-10-31: "whenever i start a
/// chat it should be able to send me to cloud autommatically".
export function cloudStartFolder(project: string | undefined): { cwd: string } | { home: true } {
  const folder = project?.replace(/\/+$/, "");
  // `/`, `/Users`, a home folder: never copied (NewTabScreen's homeOrAbove, CloudMoveFolder isTooBroad).
  if (!folder?.startsWith("/") || /^(?:\/(?:Users|home)(?:\/[^/]+)?)?$/.test(folder)) return { home: true };
  // A no-project chat's private agent-home folder (sessionList.ts isAgentHome) is no project either:
  // never copied.
  if (isAgentHome(folder)) return { home: true };
  return { cwd: folder };
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The New Tab page's project pick goes to the host on its click (workspace.useFolder), so a Cloud
/// send copies it (#29789): cloud.startChat copies only the pane's own folders. It is attached
/// whenever Cloud may be offered to this new chat (`offerable`), not only once the host answered
/// what the tab already sent (`sandbox.checked`): a pick made while that check was out was never
/// sent, and the Cloud start then failed with pathOutsideRoots. A project folder granted to a tab
/// the check then hands to a run is harmless. Only a folder Cloud would copy (cloudStartFolder);
/// a home or root answer asks nothing here (the local start still asks on Return).
export function newTabProjectPick(callNative: Native, offerable: boolean): { onProjectPicked?: (cwd: string) => void } {
  if (!offerable) return {};
  return {
    onProjectPicked: (cwd) => {
      if ("cwd" in cloudStartFolder(cwd)) void pickFolder(callNative, cwd, () => undefined);
    },
  };
}

/// The host's answer: ok, or a code with the host's own words when it has them.
export type CloudStartAnswer = { ok: true } | { ok: false; code: string; message?: string };

/// A page-side refusal before anything goes to the host: Cloud is picked but not offered now (Labs
/// went off, a chat is starting here), or attachments, since a Cloud chat takes text only for now
/// (the folder is copied; a pasted file is not). Either way the prompt stays; nothing is sent as a
/// chat here instead.
export function cloudPageRefusal(
  offered: boolean,
  attachmentCount: number,
): "cloud_not_now" | "cloud_attachments" | undefined {
  if (!offered) return "cloud_not_now";
  return attachmentCount > 0 ? "cloud_attachments" : undefined;
}

/// Sends `start` to the host and resolves to its answer; never rejects. The host answers once the
/// chat opens on the machine (a new machine boots in minutes), or with why it didn't.
export async function startCloudChat(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  start: CloudStart,
  key: string = crypto.randomUUID(),
): Promise<CloudStartAnswer> {
  const params: Record<string, unknown> = { task: start.task, key };
  if (start.cwd) params.cwd = start.cwd;
  else if (start.home) params.home = true;
  if (start.harness) params.harness = start.harness;
  if (start.model) params.model = start.model;
  try {
    await call("cloud.startChat", params);
    return { ok: true };
  } catch (error) {
    const { code, message, userMessage } = (error ?? {}) as {
      code?: unknown;
      message?: unknown;
      userMessage?: unknown;
    };
    const words = typeof userMessage === "string" ? userMessage : typeof message === "string" ? message : undefined;
    return {
      ok: false,
      code: typeof code === "string" && code ? code : "unavailable",
      ...(words ? { message: words } : {}),
    };
  }
}

/// One start at a time from a page: while one waits on the host (a new machine boots in minutes),
/// another Return starts nothing and says nothing, instead of a second start the host refuses.
export function oneCloudStart(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): (start: CloudStart, key?: string) => Promise<CloudStartAnswer> | undefined {
  let waiting = false;
  return (start, key) => {
    if (waiting) return undefined;
    waiting = true;
    return startCloudChat(call, start, key).finally(() => {
      waiting = false;
    });
  };
}

/// A failure the host already said in a toast (it ran the start): the page says nothing more.
export function cloudStartToasted(answer: CloudStartAnswer): boolean {
  return !answer.ok && answer.code === "cloud_start_failed";
}
