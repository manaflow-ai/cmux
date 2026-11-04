import type { PageClient } from "../shared/pageClient";
import { ACTION_RUN, CloudActions, type PreviewShareResult } from "./ops";

/** The result kept by a port row after its one-click share. */
export interface PreviewShare {
  linkId: string;
  url: string;
  expiresAt?: number;
}

/**
 * Shared native action boundary for Cloud preview sharing. The Open-app card
 * can call these functions without importing the port page or duplicating the
 * action names. The native action creates/copies the secret URL; the page only
 * keeps it long enough to render Revoke.
 */
export async function createPreviewShare(client: PageClient, machine: string, port: number): Promise<PreviewShare | undefined> {
  const result = await client.call<PreviewShareResult | null>(ACTION_RUN, {
    action: CloudActions.previewShare,
    args: { machine, port },
  });
  if (!result || result.confirmed === false || !result.linkId || !result.url) return undefined;
  return { linkId: result.linkId, url: result.url, expiresAt: result.expiresAt };
}

/** Revokes a previously-created link. */
export async function revokePreviewShare(client: PageClient, machine: string, port: number, linkId: string): Promise<boolean> {
  const result = await client.call<PreviewShareResult | null>(ACTION_RUN, {
    action: CloudActions.previewRevoke,
    args: { machine, port, linkId },
  });
  return result?.confirmed !== false && result?.revoked === true;
}
