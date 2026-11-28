// Settings > Cloud > Spending (RFD 0080 "Spend controls"), behind the app's `cmux.cloud.spendingWrite` (default off).
// While the app answers `cmux.settings.cloud.spending.state` with a refusal (the switch off, signed out, or an app
// without it) the card draws nothing and the page is as before. On, the overage limit saves on the person's change
// as cmux-api `usage.cap.set {overage_usd}` with their session; Rust (cmux-cloud-start-core `spending_write`) decides
// the call and words the answer, which the card shows as it is. "Ask before above" has no write yet and stays local.
import { useEffect, useRef, useState } from "react";
import { useStore } from "../context";
import { DEFAULT_SPENDING, type SpendingSettings, spendingModel } from "../spending";
import { SpendingCardView } from "./SpendingCard";

export function CloudSpendingCard() {
  const store = useStore();
  const [available, setAvailable] = useState(false);
  const [settings, setSettings] = useState<SpendingSettings>(DEFAULT_SPENDING);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The save a retryable refusal left: the same amount again reuses its key, so a lost answer never sets it twice.
  const pending = useRef<{ usd: number | null; key: string } | null>(null);

  useEffect(() => {
    let live = true;
    void store.spendingAvailable().then((on) => live && setAvailable(on));
    return () => {
      live = false;
    };
  }, [store]);

  if (!available) return null;

  const save = async (usd: number | null) => {
    const key = pending.current?.usd === usd ? pending.current.key : crypto.randomUUID();
    pending.current = { usd, key };
    setBusy(true);
    const outcome = await store.spendingSave(usd, key);
    setBusy(false);
    if (outcome.kind === "saved") {
      pending.current = null;
      setError(null);
      setSettings((before) => ({ ...before, overage_limit_usd: outcome.overageUsd }));
      return;
    }
    if (outcome.kind === "invalid" || !outcome.retry) pending.current = null;
    setError(outcome.message);
  };

  return (
    <SpendingCardView
      model={spendingModel(settings, null, "en")}
      layout="rows"
      busy={busy}
      error={error}
      onLimitChange={(usd) => void save(usd)}
      onAskAboveChange={(shape) => setSettings((before) => ({ ...before, ask_above: shape }))}
    />
  );
}
