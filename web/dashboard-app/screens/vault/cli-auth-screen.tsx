"use client";

import { useMutation, useQuery } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { dashboardFetch } from "../../lib/api";
import {
  approveCliAuthResponseSchema,
  normalizeCliUserCode,
  vaultCliAuthClientQuery,
} from "../../queries/vault";
import { vaultCliAuthRoute } from "../../routes/vault";

/** `/dashboard/vault/cli-auth`: approve a CLI device-flow sign-in. */
export function VaultCliAuthScreen() {
  const { code } = vaultCliAuthRoute.useSearch();
  const initialCode = normalizeCliUserCode(code);
  // The loader already resolved the client for a valid code; an invalid code
  // has no pending request to name.
  const { data } = useQuery({ ...vaultCliAuthClientQuery(initialCode), enabled: initialCode !== "" });
  return <VaultCliAuthView initialCode={initialCode} coderouter={data?.client === "subrouter"} />;
}

export function VaultCliAuthView({
  initialCode,
  coderouter,
}: {
  readonly initialCode: string;
  readonly coderouter: boolean;
}) {
  const t = useTranslations("vault.cliAuth");
  return (
    <div className="mx-auto w-full max-w-3xl px-3 py-4">
      <div className="border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">
          {t(coderouter ? "coderouterEyebrow" : "eyebrow")}
        </p>
        <h1 className="mt-1 text-sm font-medium">
          {t(coderouter ? "coderouterTitle" : "title")}
        </h1>
        <p className="mt-1 max-w-2xl text-muted">
          {t(coderouter ? "coderouterDescription" : "description")}
        </p>
      </div>
      <ApproveForm key={initialCode} initialCode={initialCode} />
    </div>
  );
}

function ApproveForm({ initialCode }: { readonly initialCode: string }) {
  const t = useTranslations("vault.cliAuth");
  const [code, setCode] = useState(initialCode);
  const approve = useMutation({
    mutationFn: (userCode: string) =>
      dashboardFetch("/api/vault/cli/auth/approve", approveCliAuthResponseSchema, {
        method: "POST",
        json: { userCode },
      }),
  });

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        approve.mutate(code);
      }}
      className="mt-4 flex max-w-sm flex-col gap-2"
    >
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
        disabled={approve.isPending}
        className="border border-border bg-background px-3 py-1.5 font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background disabled:cursor-not-allowed disabled:hover:bg-background disabled:hover:text-foreground"
      >
        {approve.isPending ? t("approving") : t("approveButton")}
      </button>
      {approve.isSuccess ? <p className="text-muted">{t("success")}</p> : null}
      {approve.isError ? <p className="text-muted">{t("error")}</p> : null}
    </form>
  );
}
