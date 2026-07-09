"use client";

import { useState, useTransition } from "react";
import { useTranslations } from "next-intl";

export function CreateTeamForm() {
  const t = useTranslations("dashboard.team");
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  return (
    <form
      className="border border-border p-3"
      onSubmit={(event) => {
        event.preventDefault();
        setError(null);
        startTransition(async () => {
          const response = await fetch("/api/team", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ action: "create", displayName: name }),
          });
          if (response.ok) {
            window.location.reload();
            return;
          }
          setError(t("errors.createFailed"));
        });
      }}
    >
      <h2 className="text-sm font-medium">{t("create.title")}</h2>
      <p className="mt-1 text-xs text-muted">{t("create.body")}</p>
      <div className="mt-3 flex flex-col gap-2 md:flex-row">
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder={t("create.placeholder")}
          className="min-w-0 flex-1 border border-border bg-background px-3 py-2 text-sm"
        />
        <button
          type="submit"
          disabled={isPending || !name.trim()}
          className="border border-border px-3 py-2 text-sm hover:bg-foreground hover:text-background disabled:opacity-50"
        >
          {t("create.submit")}
        </button>
      </div>
      {error ? <p className="mt-2 text-xs text-muted">{error}</p> : null}
    </form>
  );
}
