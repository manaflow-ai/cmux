"use client";

import { useTranslations } from "next-intl";
import { useState, type ChangeEvent, type FormEvent, type ReactNode } from "react";

const initialForm = {
  firstName: "",
  lastName: "",
  companyName: "",
  jobFunction: "",
  jobTitle: "",
  businessEmail: "",
  phoneNumber: "",
  country: "",
  companySize: "",
  deploymentNeeds: "",
  comments: "",
};

type FormState = typeof initialForm;
type FormKey = keyof FormState;

export function EnterpriseContactForm() {
  const t = useTranslations("enterprise.form");
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
      const response = await fetch("/api/enterprise/contact", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...form, source: "enterprise_page" }),
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

  const jobFunctionOptions = t.raw("jobFunctionOptions") as string[];
  const companySizeOptions = t.raw("companySizeOptions") as string[];
  const deploymentOptions = t.raw("deploymentNeedsOptions") as string[];

  return (
    <form onSubmit={submit} className="grid gap-5" noValidate={false}>
      <div className="grid gap-5 sm:grid-cols-2">
        <Field label={t("firstName")} required>
          <input
            name="firstName"
            value={form.firstName}
            onChange={update("firstName")}
            required
            autoComplete="given-name"
            className={inputClass}
          />
        </Field>
        <Field label={t("lastName")} required>
          <input
            name="lastName"
            value={form.lastName}
            onChange={update("lastName")}
            required
            autoComplete="family-name"
            className={inputClass}
          />
        </Field>
      </div>

      <Field label={t("companyName")} required>
        <input
          name="companyName"
          value={form.companyName}
          onChange={update("companyName")}
          required
          autoComplete="organization"
          className={inputClass}
        />
      </Field>

      <div className="grid gap-5 sm:grid-cols-2">
        <Field label={t("jobFunction")}>
          <select
            name="jobFunction"
            value={form.jobFunction}
            onChange={update("jobFunction")}
            className={inputClass}
          >
            <option value="">{t("selectPlaceholder")}</option>
            {jobFunctionOptions.map((option) => (
              <option key={option} value={option}>
                {option}
              </option>
            ))}
          </select>
        </Field>
        <Field label={t("jobTitle")} required>
          <input
            name="jobTitle"
            value={form.jobTitle}
            onChange={update("jobTitle")}
            required
            autoComplete="organization-title"
            className={inputClass}
          />
        </Field>
      </div>

      <div className="grid gap-5 sm:grid-cols-2">
        <Field label={t("businessEmail")} required>
          <input
            name="businessEmail"
            type="email"
            value={form.businessEmail}
            onChange={update("businessEmail")}
            required
            autoComplete="email"
            className={inputClass}
          />
        </Field>
        <Field label={t("phoneNumber")} required>
          <input
            name="phoneNumber"
            type="tel"
            value={form.phoneNumber}
            onChange={update("phoneNumber")}
            required
            autoComplete="tel"
            className={inputClass}
          />
        </Field>
      </div>

      <div className="grid gap-5 sm:grid-cols-2">
        <Field label={t("country")} required>
          <input
            name="country"
            value={form.country}
            onChange={update("country")}
            required
            autoComplete="country-name"
            className={inputClass}
          />
        </Field>
        <Field label={t("companySize")}>
          <select
            name="companySize"
            value={form.companySize}
            onChange={update("companySize")}
            className={inputClass}
          >
            <option value="">{t("selectPlaceholder")}</option>
            {companySizeOptions.map((option) => (
              <option key={option} value={option}>
                {option}
              </option>
            ))}
          </select>
        </Field>
      </div>

      <Field label={t("deploymentNeeds")}>
        <select
          name="deploymentNeeds"
          value={form.deploymentNeeds}
          onChange={update("deploymentNeeds")}
          className={inputClass}
        >
          <option value="">{t("selectPlaceholder")}</option>
          {deploymentOptions.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      </Field>

      <Field label={t("comments")}>
        <textarea
          name="comments"
          value={form.comments}
          onChange={update("comments")}
          rows={5}
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
  required,
  children,
}: {
  label: string;
  required?: boolean;
  children: ReactNode;
}) {
  return (
    <label className="grid gap-2 text-sm font-medium">
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
