import type { PageClient } from "../shared/pageClient";
import { ACTION_RUN, CloudActions, type PreviewShareResult } from "./ops";

/** The result kept by a port row after its one-click share. */
export interface PreviewShare {
  linkId: string;
  url: string;
  expiresAt?: number;
}

type ActionReply = PreviewShareResult & {
  ran?: boolean;
  result?: unknown;
  value?: unknown;
};

/**
 * The native action bridge has two envelopes in the wild: older page hosts
 * returned the action fields directly, while the catalog runner wraps the
 * awaited result in `{ran, result}` (and older callers used `value`). Keep
 * this boundary tolerant so the port page and the Open-app card share one
 * action without knowing which host is serving it.
 */
function actionResult(value: unknown): PreviewShareResult | undefined {
  if (!value || typeof value !== "object") return undefined;
  const reply = value as ActionReply;
  if (reply.ran === false) return undefined;
  const nested = reply.result ?? reply.value;
  if (nested !== undefined) {
    if (!nested || typeof nested !== "object") return undefined;
    return nested as PreviewShareResult;
  }
  return reply;
}

function validShare(result: PreviewShareResult | undefined, machine: string, port: number): PreviewShare | undefined {
  const copied = (result as (PreviewShareResult & { copied?: boolean }) | undefined)?.copied;
  if (!result || result.confirmed === false || copied === false) return undefined;
  if (result.machine_id !== undefined && result.machine_id !== machine) return undefined;
  if (result.port !== undefined && result.port !== port) return undefined;
  if (typeof result.linkId !== "string" || result.linkId.length === 0) return undefined;
  if (typeof result.url !== "string" || result.url.length === 0) return undefined;
  if (result.expiresAt !== undefined && (!Number.isFinite(result.expiresAt) || result.expiresAt <= 0)) return undefined;
  return { linkId: result.linkId, url: result.url, expiresAt: result.expiresAt };
}

/**
 * Shared native action boundary for Cloud preview sharing. The Open-app card
 * can call these functions without importing the port page or duplicating the
 * action names. The native action creates/copies the secret URL; the page only
 * keeps it long enough to render Revoke.
 */
export async function createPreviewShare(
  client: PageClient,
  machine: string,
  port: number,
): Promise<PreviewShare | undefined> {
  const reply = await client.call<ActionReply | null>(ACTION_RUN, {
    action: CloudActions.previewShare,
    target: `machine:${machine}`,
    args: { port },
  });
  return validShare(actionResult(reply), machine, port);
}

/** Revokes a previously-created link. */
export async function revokePreviewShare(
  client: PageClient,
  machine: string,
  port: number,
  linkId: string,
): Promise<boolean> {
  const reply = await client.call<ActionReply | null>(ACTION_RUN, {
    action: CloudActions.previewRevoke,
    target: `machine:${machine}`,
    args: { port, linkId },
  });
  const result = actionResult(reply);
  // The platform's idempotent revoke answers `false` when the link was
  // already revoked. That is still success for the UI: remove Revoke and do
  // not surface an error for a state that is already safe.
  return result?.confirmed !== false && (result?.revoked === true || result?.revoked === false);
}
