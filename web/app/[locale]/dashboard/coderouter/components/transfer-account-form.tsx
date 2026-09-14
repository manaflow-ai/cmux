"use client";
import { useState } from "react";
export function TransferAccountForm({ accountId, teams }: { accountId: string; teams: readonly { id: string; name: string }[] }) {
  const [team, setTeam] = useState(teams[0]?.id ?? ""); const [message, setMessage] = useState("");
  async function submit() { if (!team) return; setMessage("Transferring…"); const r = await fetch(`/api/coderouter/accounts/${accountId}/transfer`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ destinationTeamId: team }) }); setMessage(r.ok ? "Transferred. Refresh to update." : "Transfer failed."); }
  return <span className="flex items-center gap-2"><select aria-label="Destination team" value={team} onChange={e => setTeam(e.target.value)} className="border border-border bg-transparent px-1 text-xs">{teams.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><button type="button" onClick={submit} disabled={!team || message === "Transferring…"} className="text-xs underline">Transfer</button>{message ? <span className="text-xs text-muted">{message}</span> : null}</span>;
}
