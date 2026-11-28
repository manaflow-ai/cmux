"use client";

import { useTranslations } from "next-intl";
import { useState, type FormEvent } from "react";

export function RecoverBillingForm() {
  const t = useTranslations("billingRecovery");
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "submitting" | "success" | "error">("idle");
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (status === "submitting") return;
    setStatus("submitting");
    setError("");

    try {
      const response = await fetch("/api/billing/recover", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      if (!response.ok) {
        throw new Error(t("error"));
      }
      setStatus("success");
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : t("error"));
      setStatus("error");
    }
  }

  return (
    <form onSubmit={submit} className="grid gap-5">
      <label htmlFor="billing-recovery-email" className="grid gap-2 text-sm font-medium">
        <span>{t("emailLabel")}</span>
        <input
          id="billing-recovery-email"
          name="email"
          type="email"
          value={email}
          onChange={(event) => {
            setEmail(event.target.value);
            if (status !== "submitting") setStatus("idle");
          }}
          placeholder={t("emailPlaceholder")}
          autoComplete="email"
          required
          disabled={status === "submitting"}
          className="h-11 w-full border border-border bg-background px-3 text-[15px] text-foreground outline-none transition-colors focus:border-foreground"
        />
      </label>

      {status === "success" ? (
        <p role="status" className="border border-border px-4 py-3 text-sm leading-relaxed">
          {t("success")}
        </p>
      ) : null}
      {status === "error" ? (
        <p role="alert" className="border border-red-500/40 px-4 py-3 text-sm leading-relaxed">
          {error}
        </p>
      ) : null}

      <button
        type="submit"
        disabled={status === "submitting"}
        className="inline-flex w-full items-center justify-center bg-foreground px-5 py-3 text-[15px] font-medium text-background transition-opacity hover:opacity-85 disabled:cursor-not-allowed disabled:opacity-55"
      >
        {status === "submitting" ? t("submitting") : t("submit")}
      </button>
    </form>
  );
}
