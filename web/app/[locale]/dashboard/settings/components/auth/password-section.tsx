"use client";

import type { CurrentUser } from "@hexclave/next";
import { KnownErrors } from "@hexclave/shared";
import { useTranslations } from "next-intl";
import { useId, useState } from "react";
import {
  InlineError,
  SettingsNotice,
  SettingsSection,
  settingsButtonClass,
  settingsInputClass,
  settingsLabelClass,
  useAsyncAction,
} from "../../../components/settings-ui";
import { hasSignInEmail } from "../../lib/contact-channels";
import {
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  hasPasswordErrors,
  validatePasswordForm,
  type PasswordFieldErrors,
  type PasswordFormValues,
} from "../../lib/password";

const EMPTY: PasswordFormValues = { oldPassword: "", newPassword: "", newPasswordRepeat: "" };

/** Set or update the password. Rendered only when credentials are enabled. */
export function PasswordSection({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.auth.password");
  const channels = user.useContactChannels();
  const [editing, setEditing] = useState(false);
  const [done, setDone] = useState(false);

  return (
    <SettingsSection
      title={t("title")}
      description={user.hasPassword ? t("updateDescription") : t("setDescription")}
    >
      {editing ? (
        <PasswordForm
          user={user}
          onClose={(saved) => {
            setEditing(false);
            setDone(saved);
          }}
        />
      ) : hasSignInEmail(channels) ? (
        <>
          <button
            type="button"
            onClick={() => {
              setDone(false);
              setEditing(true);
            }}
            className={settingsButtonClass("secondary", "sm")}
          >
            {user.hasPassword ? t("update") : t("set")}
          </button>
          {done ? <p role="status" className="text-xs text-muted">{t("saved")}</p> : null}
        </>
      ) : (
        <SettingsNotice>{t("needsSignInEmail")}</SettingsNotice>
      )}
    </SettingsSection>
  );
}

function PasswordForm({
  user,
  onClose,
}: {
  readonly user: CurrentUser;
  readonly onClose: (saved: boolean) => void;
}) {
  const t = useTranslations("dashboard.settings.auth.password");
  const ids = { old: useId(), next: useId(), repeat: useId() };
  const [values, setValues] = useState<PasswordFormValues>(EMPTY);
  const [errors, setErrors] = useState<PasswordFieldErrors>({});
  const [serverError, setServerError] = useState<"incorrect" | "requirements" | null>(null);
  const [run, state] = useAsyncAction(t("saveError"));

  const change = (field: keyof PasswordFormValues, value: string) => {
    setValues((current) => ({ ...current, [field]: value }));
    setErrors({});
    setServerError(null);
    state.clearError();
  };

  const submit = async () => {
    const found = validatePasswordForm(values, user.hasPassword);
    setErrors(found);
    if (hasPasswordErrors(found)) return;
    let result: unknown;
    const ok = await run(async () => {
      result = user.hasPassword
        ? await user.updatePassword({ oldPassword: values.oldPassword, newPassword: values.newPassword })
        : await user.setPassword({ password: values.newPassword });
    });
    if (!ok) return;
    if (!result) {
      onClose(true);
      return;
    }
    // Hexclave mapped every returned error to "Incorrect password"; keep that
    // for the old password and report requirement failures on the new one.
    setServerError(
      KnownErrors.PasswordRequirementsNotMet.isInstance(result) ? "requirements" : "incorrect",
    );
  };

  const fieldError = (field: keyof PasswordFieldErrors) => {
    const code = errors[field];
    return code ? t(`errors.${field}.${code}`, { min: PASSWORD_MIN_LENGTH, max: PASSWORD_MAX_LENGTH }) : null;
  };

  return (
    <form
      noValidate
      className="flex w-full flex-col gap-3 sm:max-w-sm"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      {user.hasPassword ? (
        <div className="space-y-1">
          <label htmlFor={ids.old} className={settingsLabelClass}>{t("oldPassword")}</label>
          <input
            id={ids.old}
            type="password"
            autoComplete="current-password"
            value={values.oldPassword}
            onChange={(event) => change("oldPassword", event.target.value)}
            className={settingsInputClass}
          />
          <InlineError message={serverError === "incorrect" ? t("incorrect") : fieldError("oldPassword")} />
        </div>
      ) : null}
      <div className="space-y-1">
        <label htmlFor={ids.next} className={settingsLabelClass}>{t("newPassword")}</label>
        <input
          id={ids.next}
          type="password"
          autoComplete="new-password"
          value={values.newPassword}
          onChange={(event) => change("newPassword", event.target.value)}
          className={settingsInputClass}
        />
        <InlineError message={serverError === "requirements" ? t("requirements") : fieldError("newPassword")} />
      </div>
      <div className="space-y-1">
        <label htmlFor={ids.repeat} className={settingsLabelClass}>{t("repeatPassword")}</label>
        <input
          id={ids.repeat}
          type="password"
          autoComplete="new-password"
          value={values.newPasswordRepeat}
          onChange={(event) => change("newPasswordRepeat", event.target.value)}
          className={settingsInputClass}
        />
        <InlineError message={fieldError("newPasswordRepeat")} />
      </div>
      <InlineError message={state.error} />
      <div className="flex gap-2">
        <button type="submit" disabled={state.pending} className={settingsButtonClass("primary", "sm")}>
          {state.pending ? t("saving") : user.hasPassword ? t("updateSubmit") : t("setSubmit")}
        </button>
        <button type="button" disabled={state.pending} onClick={() => onClose(false)} className={settingsButtonClass("secondary", "sm")}>
          {t("cancel")}
        </button>
      </div>
    </form>
  );
}
