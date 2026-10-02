import { AcpmuxRpcError, HANDOFF_OPS, handoffRecord, type Handoff, type StartReceipt } from "./protocol";
import { reviewedContinuation, type HandoffReviewInput } from "./review";

type Request = (method: string, params: Record<string, unknown>) => Promise<any>;
export type HandoffClientState = {
  ready?: boolean;
  record?: Handoff;
  busy?: "preparing" | "saving" | "starting" | "discarding";
  error?: string;
  conflict?: boolean;
  receipt?: StartReceipt;
};

/** A projection of daemon-owned handoffs. Keys identify attempts; only RPC results change records. */
export class HandoffClient {
  state: HandoffClientState = {};
  private sessionId?: string;
  private selection = 0;
  private prepareAttempt?: { sessionId: string; harness: string; handoffKey: string };
  private preparing?: { sessionId?: string; harness: string; promise: Promise<Handoff | undefined> };
  private starting?: { selection: number; promise: Promise<StartReceipt | undefined> };
  private ownRevisions = new Map<string, Map<number, number>>();
  private uncertainDraft?: { content: string; params: Record<string, unknown> };
  private saved: Promise<unknown> = Promise.resolve();
  constructor(
    private request: Request,
    private changed: () => void,
    private key: () => string = () => crypto.randomUUID(),
  ) {}

  select(sessionId?: string): void {
    this.sessionId = sessionId;
    this.selection += 1;
    this.state = {};
  }
  disconnect(): void {
    this.state.ready = false;
    this.changed();
  }
  private adopt(record: Handoff): void {
    if (this.sessionId === record.source.sessionId || this.sessionId === record.target.sessionId)
      this.state.record = record;
  }
  async refresh(): Promise<void> {
    const sessionId = this.sessionId;
    const selection = this.selection;
    if (!sessionId) return;
    const result = await this.request(HANDOFF_OPS.get, { sessionId });
    if (selection !== this.selection) return;
    this.state = { ready: true, record: result === null ? undefined : handoffRecord(result) };
    this.changed();
  }
  prepare(harness: string): Promise<Handoff | undefined> {
    if (this.preparing && this.preparing.sessionId === this.sessionId && this.preparing.harness === harness)
      return this.preparing.promise;
    const promise = this.prepareOnce(harness);
    const attempt = { sessionId: this.sessionId, harness, promise };
    this.preparing = attempt;
    void promise
      .finally(() => {
        if (this.preparing === attempt) this.preparing = undefined;
      })
      .catch(() => undefined);
    return promise;
  }
  private async prepareOnce(harness: string): Promise<Handoff | undefined> {
    const sessionId = this.sessionId;
    if (!sessionId || !this.state.ready || this.state.busy) return;
    const selection = this.selection;
    this.state.error = undefined;
    this.state.busy = "preparing";
    this.changed();
    try {
      const current = this.state.record;
      if (current?.state === "draft" && current.source.sessionId === sessionId && current.target.harness === harness)
        return current;
      const pending = this.prepareAttempt;
      this.prepareAttempt =
        pending?.sessionId === sessionId && pending.harness === harness
          ? pending
          : { sessionId, harness, handoffKey: this.key() };
      const result = handoffRecord(await this.request(HANDOFF_OPS.prepare, this.prepareAttempt));
      this.prepareAttempt = undefined;
      if (selection !== this.selection) return;
      this.adopt(result);
      return result;
    } catch (error) {
      if (selection === this.selection)
        this.state.error = error instanceof Error ? error.message : "Couldn't prepare this continuation.";
      throw error;
    } finally {
      if (selection === this.selection) {
        this.state.busy = undefined;
        this.changed();
      }
    }
  }

  save(review: HandoffReviewInput): Promise<Handoff | undefined> {
    if (!this.state.ready || this.state.conflict) return Promise.resolve(undefined);
    const id = this.state.record?.handoffId;
    const selection = this.selection;
    const write = async () => {
      const record = this.state.record;
      if (
        !record ||
        record.handoffId !== id ||
        selection !== this.selection ||
        record.state !== "draft" ||
        !this.state.ready ||
        this.state.conflict
      )
        return;
      if (new TextEncoder().encode(review.capsule).length > record.capsule.maxBytes)
        throw new Error("Capsule exceeds the advertised byte budget.");
      this.state.busy = "saving";
      this.state.error = undefined;
      this.changed();
      let revision = review.revision ?? record.revision;
      const revisions = this.ownRevisions.get(record.handoffId);
      while (revisions?.has(revision) && revisions.get(revision)! > revision) revision = revisions.get(revision)!;
      let params = {
        handoffId: id,
        revision,
        draftKey: this.key(),
        capsule: { text: review.capsule, memoryRefs: review.approvedMemoryReferences },
        checkpoint: review.checkpoint?.confirmed ? { ref: review.checkpoint.reference, attest: true } : null,
      };
      const content = JSON.stringify({ id, review });
      if (this.uncertainDraft?.content === content) params = this.uncertainDraft.params as typeof params;
      this.uncertainDraft = { content, params };
      try {
        let result: unknown;
        try {
          result = await this.request(HANDOFF_OPS.draft, params);
        } catch (error) {
          if (error instanceof AcpmuxRpcError || !this.state.ready || selection !== this.selection) throw error;
          // Recover first, then replay the exact write key. A later peer edit is never overwritten.
          await this.request(HANDOFF_OPS.get, { handoffId: id });
          result = await this.request(HANDOFF_OPS.draft, params);
        }
        const accepted = handoffRecord(result);
        this.uncertainDraft = undefined;
        if (accepted.revision > params.revision) {
          const own = this.ownRevisions.get(record.handoffId) ?? new Map<number, number>();
          own.set(params.revision, accepted.revision);
          this.ownRevisions.set(record.handoffId, own);
        }
        if (selection === this.selection) this.adopt(accepted);
        return accepted;
      } catch (error) {
        if (selection === this.selection) {
          this.state.error = error instanceof Error ? error.message : "Couldn't save this review.";
          this.state.conflict = error instanceof AcpmuxRpcError && error.reason === "stale_revision";
        }
        throw error;
      } finally {
        if (selection === this.selection) {
          this.state.busy = undefined;
          this.changed();
        }
      }
    };
    const result = this.saved.then(write);
    this.saved = result.catch(() => undefined);
    return result;
  }

  start(review: HandoffReviewInput): Promise<StartReceipt | undefined> {
    if (this.starting && this.starting.selection === this.selection) return this.starting.promise;
    const promise = this.startOnce(review);
    const attempt = { selection: this.selection, promise };
    this.starting = attempt;
    void promise
      .finally(() => {
        if (this.starting === attempt) this.starting = undefined;
      })
      .catch(() => undefined);
    return promise;
  }
  private async startOnce(review: HandoffReviewInput): Promise<StartReceipt | undefined> {
    await this.saved;
    const record = this.state.record;
    if (
      !record ||
      !this.state.ready ||
      this.sessionId !== record.target.sessionId ||
      this.state.busy ||
      this.state.conflict ||
      this.state.receipt
    )
      return;
    reviewedContinuation(
      review.capsule,
      review.checkpoint.reference,
      review.checkpoint.confirmed,
      review.approvedMemoryReferences.join("\n"),
      record.capsule.maxBytes,
    );
    const selection = this.selection;
    // One handoff owns one prompt. Its daemon-minted UUID is stable even after a page/daemon restart.
    const params = {
      handoffId: record.handoffId,
      revision: review.revision ?? record.revision,
      promptId: record.promptId ?? record.handoffId,
      capsule: { text: review.capsule, memoryRefs: review.approvedMemoryReferences },
      checkpoint: { ref: review.checkpoint.reference, attest: true },
    };
    this.state.busy = "starting";
    this.state.error = undefined;
    this.changed();
    try {
      let receipt: StartReceipt;
      try {
        receipt = await this.request(HANDOFF_OPS.start, params);
      } catch (error) {
        if (
          (error instanceof AcpmuxRpcError && error.reason !== "uncertain_delivery") ||
          !this.state.ready ||
          selection !== this.selection
        )
          throw error;
        const restored = handoffRecord(await this.request(HANDOFF_OPS.get, { handoffId: record.handoffId }));
        if (selection === this.selection) this.adopt(restored);
        receipt = await this.request(HANDOFF_OPS.start, params);
      }
      if (
        receipt.handoffId !== record.handoffId ||
        receipt.targetSessionId !== record.target.sessionId ||
        receipt.promptId !== params.promptId ||
        !["started", "already_started"].includes(receipt.outcome)
      )
        throw new Error("Invalid continuation acknowledgement.");
      if (selection === this.selection) {
        this.state.receipt = receipt;
        const updated = handoffRecord(await this.request(HANDOFF_OPS.get, { handoffId: record.handoffId }));
        if (selection === this.selection) this.adopt(updated);
      }
      return receipt;
    } catch (error) {
      if (selection === this.selection) {
        this.state.error = error instanceof Error ? error.message : "Couldn't confirm this continuation.";
        this.state.conflict = error instanceof AcpmuxRpcError && error.reason === "stale_revision";
      }
      throw error;
    } finally {
      if (selection === this.selection) {
        this.state.busy = undefined;
        this.changed();
      }
    }
  }

  async discard(): Promise<Handoff | undefined> {
    await this.saved;
    const record = this.state.record;
    if (!record || !this.state.ready || this.state.busy) return;
    const selection = this.selection;
    this.state.busy = "discarding";
    this.changed();
    try {
      const result = await this.request(HANDOFF_OPS.discard, { handoffId: record.handoffId });
      if (result?.discarded !== true) throw new Error("Couldn't discard this continuation.");
      if (selection === this.selection) this.state = { ready: true };
      return record;
    } catch (error) {
      if (selection === this.selection)
        this.state.error = error instanceof Error ? error.message : "Couldn’t discard this continuation.";
      throw error;
    } finally {
      if (selection === this.selection) {
        this.state.busy = undefined;
        this.changed();
      }
    }
  }
}
