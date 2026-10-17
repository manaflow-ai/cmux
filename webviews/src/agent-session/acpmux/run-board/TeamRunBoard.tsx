// l10n-allow-file: first team-facing Run board slice; copy is intentionally product-facing and
// will move into the generated strings table once the team workflow wording settles.
import { useState } from "react";
import { RunBoard, type RunBoardProps } from "./RunBoard";
import { createRunApiClient, RunBoardApiSession, type RunApiClient, type RunAttachTarget, type RunCreateInput } from "./runApi";
import type { AttachTicket, ApprovalIntent, RunBoardSnapshot } from "./model";

// Keep the network client and the product flow together. The board itself remains a pure
// projection, which is what the gallery and replay tests exercise.
export type TeamRunBoardProps = {
  client?: RunApiClient;
  onClose?: () => void;
  onAttachTarget?: (target: RunAttachTarget) => Promise<void>;
};

type CreateState = {
  repository: string;
  commit: string;
  attempts: number;
  provider: "freestyle" | "huge-blue";
};

const initialCreate: CreateState = { repository: "", commit: "", attempts: 4, provider: "freestyle" };

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function TeamRunBoard({ client = createRunApiClient(), onClose, onAttachTarget }: TeamRunBoardProps) {
  const [create, setCreate] = useState<CreateState>(initialCreate);
  const [snapshot, setSnapshot] = useState<RunBoardSnapshot>();
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState(false);
  const [promotion, setPromotion] = useState<string>();

  const createRun = async (event: React.FormEvent) => {
    event.preventDefault();
    if (pending) return;
    setError(undefined);
    setPending(true);
    try {
      const input: RunCreateInput = {
        source: { repository: create.repository.trim(), commit: create.commit.trim() },
        recipe: "parallel-review",
        desiredAttempts: create.attempts,
        provider: "cloud-vm",
        routing: { requestedProvider: create.provider },
      };
      const created = await client.createRun(input, `cmux-run-board:${crypto.randomUUID()}`);
      setSnapshot(await new RunBoardApiSession(created.id, client).snapshotAndReplay());
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setPending(false);
    }
  };

  const onAttach = async (intent: Parameters<NonNullable<RunBoardProps["onAttach"]>>[0]): Promise<AttachTicket> => {
    const minted = await client.mintAttachTicket(intent.runId, intent.attemptId);
    const target = await client.redeemAttachTicket(intent.runId, intent.attemptId, minted.ticket);
    await onAttachTarget?.(target);
    return { ...intent, ticket: minted.ticket, expiresAt: minted.expiresAt };
  };

  const onApprove = async (intent: ApprovalIntent) => {
    const result = await client.promoteAttempt(intent.runId, intent.attemptId, `cmux-run-promote:${intent.runId}:${intent.attemptId}`);
    setPromotion(result.runtime?.id ? `Promoted to persistent runtime ${result.runtime.id}.` : "Promotion accepted.");
  };

  if (snapshot) {
    return (
      <div className="run-board-host">
        <div className="run-board-host-bar">
          <span>Team Run board</span>
          <div>
            {promotion && <span className="run-board-host-receipt" role="status">{promotion}</span>}
            {onClose && <button type="button" onClick={onClose}>Close</button>}
          </div>
        </div>
        <RunBoard snapshot={snapshot} recovered={snapshot} client={client} onAttach={onAttach} onApprove={onApprove} />
      </div>
    );
  }

  return (
    <div className="run-board-host run-board-launcher">
      <div className="run-board-host-bar">
        <div>
          <span>Team Run board</span>
          <small>Bounded fan-out, evidence, and promotion</small>
        </div>
        {onClose && <button type="button" onClick={onClose}>Close</button>}
      </div>
      <form onSubmit={(event) => void createRun(event)} className="run-board-create" aria-label="Create a fan-out Run">
        <h1>Start a Run</h1>
        <p>One immutable source and intent, with independent worker VMs that can be compared before a winner becomes a dev box.</p>
        <label>
          Repository
          <input required value={create.repository} placeholder="github.com/manaflow-ai/cmux" onChange={(event) => setCreate((current) => ({ ...current, repository: event.currentTarget.value }))} />
        </label>
        <label>
          Commit SHA
          <input required pattern="[0-9a-fA-F]{40}" value={create.commit} placeholder="40-character immutable commit" onChange={(event) => setCreate((current) => ({ ...current, commit: event.currentTarget.value }))} />
        </label>
        <div className="run-board-create-row">
          <label>
            Attempts
            <input type="number" min={1} max={32} value={create.attempts} onChange={(event) => setCreate((current) => ({ ...current, attempts: Number(event.currentTarget.value) }))} />
          </label>
          <label>
            Backend
            <select value={create.provider} onChange={(event) => setCreate((current) => ({ ...current, provider: event.currentTarget.value as CreateState["provider"] }))}>
              <option value="freestyle">Freestyle</option>
              <option value="huge-blue">Huge Blue (when enabled)</option>
            </select>
          </label>
        </div>
        <div className="run-board-create-note"><strong>Fan-out</strong> runs the same recipe independently. <strong>Thunderdome</strong> is the comparison policy layered on top: review artifacts and receipts, then promote one attempt.</div>
        {error && <p className="run-board-api-error" role="alert">{error}</p>}
        <button className="run-board-create-submit" type="submit" disabled={pending}>{pending ? "Starting workers…" : "Create fan-out"}</button>
      </form>
    </div>
  );
}
