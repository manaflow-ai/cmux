import { DurableObject } from "cloudflare:workers";
import {
  emptyOwnerIndex,
  pruneOwnerIndex,
  reserveOwnerShare,
  type OwnerIndexState,
} from "./shareOwnerState";

const STATE_KEY = "owner:index";

export class ShareOwnerIndex extends DurableObject<Record<string, never>> {
  async reserve(shareId: string, expiresAt: number, now = Date.now()): Promise<{ ok: true } | { ok: false; error: string }> {
    return this.ctx.storage.transaction(async (transaction) => {
      const current = await transaction.get<OwnerIndexState>(STATE_KEY) ?? emptyOwnerIndex();
      const result = reserveOwnerShare(current, shareId, expiresAt, now);
      await transaction.put(STATE_KEY, result.state);
      return result.ok ? { ok: true } : { ok: false, error: result.error };
    });
  }

  async release(shareId: string, now = Date.now()): Promise<void> {
    await this.ctx.storage.transaction(async (transaction) => {
      const current = await transaction.get<OwnerIndexState>(STATE_KEY) ?? emptyOwnerIndex();
      const state = pruneOwnerIndex(current, now);
      await transaction.put(STATE_KEY, {
        ...state,
        activeShares: state.activeShares.filter((share) => share.shareId !== shareId),
      });
    });
  }
}
