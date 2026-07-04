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
    <form onSubmit={onSubmit} className="mt-6 flex max-w-sm flex-col gap-3">
      <label className="text-sm font-medium text-foreground" htmlFor="vault-user-code">
        {t("codeLabel")}
      </label>
      <input
        id="vault-user-code"
        value={code}
        onChange={(event) => setCode(event.target.value.toUpperCase())}
        className="h-10 rounded-md border border-border bg-background px-3 font-mono text-sm uppercase outline-none focus:border-foreground"
        autoComplete="one-time-code"
        inputMode="text"
        maxLength={8}
      />
      <button
        type="submit"
        disabled={state.kind === "submitting"}
        className="h-10 rounded-md bg-foreground px-4 text-sm font-medium text-background disabled:opacity-60"
      >
        {state.kind === "submitting" ? t("approving") : t("approveButton")}
      </button>
      {state.kind === "success" ? (
        <p className="text-sm text-green-600 dark:text-green-400">{t("success")}</p>
      ) : null}
      {state.kind === "error" ? (
        <p className="text-sm text-red-600 dark:text-red-400">{state.message}</p>
      ) : null}
    </form>
  );
}
