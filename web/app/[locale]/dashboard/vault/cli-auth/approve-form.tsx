"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

type SubmitState =
  | { readonly kind: "idle" }
  | { readonly kind: "submitting" }
  | { readonly kind: "success" }
  | { readonly kind: "error"; readonly message: string };

export function ApproveForm({ initialCode }: { initialCode: string }) {
  const t = useTranslations("vault.cliAuth");
  const [code, setCode] = useState(initialCode);
  const [state, setState] = useState<SubmitState>({ kind: "idle" });

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setState({ kind: "submitting" });
    const response = await fetch("/api/vault/cli/auth/approve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ userCode: code }),
    });
    if (response.ok) {
      setState({ kind: "success" });
      return;
    }
    setState({ kind: "error", message: t("error") });
  }

  return (
    <form onSubmit={onSubmit} className="mt-4 flex max-w-sm flex-col gap-2">
      <label className="text-xs font-medium text-muted" htmlFor="vault-user-code">
        {t("codeLabel")}
      </label>
      <input
        id="vault-user-code"
        value={code}
        onChange={(event) => setCode(event.target.value.toUpperCase())}
        className="border border-border bg-background px-3 py-1.5 font-mono text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
        autoComplete="one-time-code"
        inputMode="text"
        maxLength={8}
      />
      <button
        type="submit"
        disabled={state.kind === "submitting"}
        className="border border-border bg-background px-3 py-1.5 font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background disabled:cursor-not-allowed disabled:hover:bg-background disabled:hover:text-foreground"
      >
        {state.kind === "submitting" ? t("approving") : t("approveButton")}
      </button>
      {state.kind === "success" ? (
        <p className="text-muted">{t("success")}</p>
      ) : null}
      {state.kind === "error" ? (
        <p className="text-muted">{state.message}</p>
      ) : null}
    </form>
  );
}
