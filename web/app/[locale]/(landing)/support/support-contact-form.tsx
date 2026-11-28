"use client";

import { useTranslations } from "next-intl";
import { useState, type ChangeEvent, type FormEvent, type ReactNode } from "react";

const initialForm = {
  name: "",
  email: "",
  topic: "",
  message: "",
};

type FormState = typeof initialForm;
type FormKey = keyof FormState;

export function SupportContactForm() {
  const t = useTranslations("support.form");
  const [form, setForm] = useState<FormState>(initialForm);
  const [status, setStatus] = useState<
    "idle" | "submitting" | "success" | "error"
  >("idle");
  const [error, setError] = useState("");

  const update =
    (key: FormKey) =>
    (
      event:
        | ChangeEvent<HTMLInputElement>
        | ChangeEvent<HTMLSelectElement>
        | ChangeEvent<HTMLTextAreaElement>,
    ) => {
      setStatus(status === "error" ? "idle" : status);
      setForm((current) => ({ ...current, [key]: event.target.value }));
    };

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status === "submitting") return;
    setStatus("submitting");
    setError("");

    try {
      const response = await fetch("/api/support/contact", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...form, source: "support_page" }),
      });
      if (!response.ok) {
        const body = (await response.json().catch(() => null)) as {
          error?: string;
        } | null;
        throw new Error(body?.error ?? t("error"));
      }
      setStatus("success");
      setForm(initialForm);
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : t("error"));
      setStatus("error");
    }
  };

  const topicOptions = t.raw("topicOptions") as string[];

  return (
    <form onSubmit={submit} className="grid gap-5" noValidate={false}>
      <div className="grid gap-5 sm:grid-cols-2">
        <Field label={t("name")} htmlFor="support-name">
          <input
            id="support-name"
            name="name"
            value={form.name}
            onChange={update("name")}
            autoComplete="name"
            className={inputClass}
          />
        </Field>
        <Field label={t("email")} htmlFor="support-email" required>
          <input
            id="support-email"
            name="email"
            type="email"
            value={form.email}
            onChange={update("email")}
            required
            autoComplete="email"
            className={inputClass}
          />
        </Field>
      </div>

      <Field label={t("topic")} htmlFor="support-topic">
        <select
          id="support-topic"
          name="topic"
          value={form.topic}
          onChange={update("topic")}
          className={inputClass}
        >
          <option value="">{t("selectPlaceholder")}</option>
          {topicOptions.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      </Field>

      <Field label={t("message")} htmlFor="support-message" required>
        <textarea
          id="support-message"
          name="message"
          value={form.message}
          onChange={update("message")}
          required
          rows={7}
          className={`${inputClass} resize-y py-3`}
        />
      </Field>

      <p className="text-sm leading-relaxed text-muted">{t("privacy")}</p>

      {status === "success" ? (
        <p role="status" className="border border-border px-4 py-3 text-sm">
          {t("success")}
        </p>
      ) : null}
      {status === "error" ? (
        <p role="alert" className="border border-red-500/40 px-4 py-3 text-sm">
          {error || t("error")}
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

function Field({
  label,
  htmlFor,
  required,
  children,
}: {
  label: string;
  htmlFor: string;
  required?: boolean;
  children: ReactNode;
}) {
  return (
    <label htmlFor={htmlFor} className="grid gap-2 text-sm font-medium">
      <span>
        {label}
        {required ? <span className="text-muted"> *</span> : null}
      </span>
      {children}
    </label>
  );
}

const inputClass =
  "h-11 w-full border border-border bg-background px-3 text-[15px] text-foreground outline-none transition-colors focus:border-foreground";
