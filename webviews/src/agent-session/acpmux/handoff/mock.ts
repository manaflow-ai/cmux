import { HANDOFF_OPS, type Handoff, type StartReceipt } from "./protocol";

/** Deterministic owner stand-in for pane interaction tests. Never used by a live daemon. */
export class MockHandoffs {
  private records = new Map<string, Handoff>();
  private writes = new Map<string, Handoff>();
  constructor(private sessions: () => Record<string, any>[], private create: (source: Record<string, any>, harness: string) => string,
    private context: (id: string) => { text: string; seq: number },
    private prompt: (id: string, text: string, promptId: string) => Promise<unknown>, private remove: (id: string) => void) {}
  private fail(reason: string, handoff?: Handoff): never {
    throw Object.assign(new Error(reason), { data: { reason, handoff } });
  }
  private checkpoint(input: any) {
    if (!input?.attest || typeof input.ref !== "string" || !input.ref.trim()) this.fail("checkpoint_unattested");
    return { ref: input.ref, attestedBy: "user" as const, attestedAt: new Date().toISOString() };
  }
  async answer(method: string, params: Record<string, any>): Promise<unknown> {
    if (method === HANDOFF_OPS.get) {
      if (params.handoffId) return structuredClone(this.records.get(params.handoffId) ?? this.fail("not_found"));
      return structuredClone([...this.records.values()].reverse().find((r) => r.state !== "discarded"
        && [r.source.sessionId, r.target.sessionId].includes(params.sessionId)) ?? null);
    }
    if (method === HANDOFF_OPS.prepare) {
      const replay = [...this.records.values()].find((r) => r.handoffKey === params.handoffKey);
      if (replay) return structuredClone(replay);
      const source = this.sessions().find((s) => s.sessionId === params.sessionId) ?? this.fail("not_found");
      if (source.status === "running" || source.queue?.length) this.fail("source_busy");
      if (source.harness === params.harness) this.fail("same_harness");
      const checkpoint = params.checkpoint ? this.checkpoint(params.checkpoint) : null;
      const targetId = this.create(source, params.harness);
      const captured = this.context(source.sessionId);
      let text = captured.text;
      while (new TextEncoder().encode(text).length > 65536) text = text.slice(1);
      const contextBytes = new TextEncoder().encode(text).length;
      const enforcement = source.enforcement ?? { policy: "default", label: "native_policy", isolation: "unverified", detail: null };
      const coverage = [{ item: "transcript" as const, status: "summarized" as const, detail: null }];
      const now = new Date().toISOString();
      const record: Handoff = { handoffId: crypto.randomUUID(), handoffKey: params.handoffKey, state: "draft", revision: 1,
        source: { sessionId: source.sessionId, cwd: source.cwd, harness: source.harness, seq: captured.seq, coverage, enforcement },
        target: { sessionId: targetId, cwd: source.cwd, harness: params.harness, coverage, enforcement },
        capsule: { text, maxBytes: 65536, context: { fromSeq: 0, toSeq: captured.seq, truncated: text !== captured.text,
          bytes: contextBytes, totalBytes: new TextEncoder().encode(captured.text).length }, checkpoint, memoryRefs: params.memoryRefs ?? [] },
        promptId: null, turnId: null, createdAt: now, updatedAt: now };
      this.records.set(record.handoffId, record);
      return structuredClone(record);
    }
    const record = this.records.get(params.handoffId) ?? this.fail("not_found");
    if (method === HANDOFF_OPS.discard) {
      if (["starting", "started"].includes(record.state)) this.fail("already_started", record);
      record.state = "discarded"; this.remove(record.target.sessionId);
      return { handoffId: record.handoffId, discarded: true };
    }
    const promptId = params.promptId ?? record.handoffId;
    const receipt = (outcome: StartReceipt["outcome"]): StartReceipt => ({ handoffId: record.handoffId,
      targetSessionId: record.target.sessionId, promptId, turnId: record.turnId, outcome });
    if (method === HANDOFF_OPS.start && record.promptId) {
      if (promptId !== record.promptId) this.fail("already_started", record);
      return receipt("already_started");
    }
    const writeId = `${record.handoffId}:${params.draftKey}`;
    if (method === HANDOFF_OPS.draft && this.writes.has(writeId)) return structuredClone(this.writes.get(writeId));
    if (record.state !== "draft") this.fail("not_draft", record);
    const text = params.capsule.text;
    if (new TextEncoder().encode(text).length > record.capsule.maxBytes) this.fail("capsule_too_large");
    const refs = params.capsule.memoryRefs ?? record.capsule.memoryRefs;
    const checkpoint = params.checkpoint === null ? null : params.checkpoint ? this.checkpoint(params.checkpoint) : record.capsule.checkpoint;
    if (params.revision !== record.revision && (text !== record.capsule.text || JSON.stringify(refs) !== JSON.stringify(record.capsule.memoryRefs)
      || checkpoint?.ref !== record.capsule.checkpoint?.ref)) this.fail("stale_revision", record);
    record.capsule = { ...record.capsule, text, memoryRefs: refs, checkpoint };
    if (method === HANDOFF_OPS.draft) {
      record.revision += 1; record.updatedAt = new Date().toISOString();
      this.writes.set(writeId, structuredClone(record)); return structuredClone(record);
    }
    if (!checkpoint) this.fail("checkpoint_required");
    record.promptId = promptId; record.state = "starting";
    // The daemon start acknowledgment does not wait for the entire agent turn.
    void this.prompt(record.target.sessionId, text, promptId);
    record.state = "started"; record.turnId = `mock-turn-${promptId}`;
    return receipt("started");
  }
}
