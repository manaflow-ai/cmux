"use client";

import { useStackApp, type CurrentUser } from "@hexclave/next";
import { createTOTPKeyURI, verifyTOTP } from "@oslojs/otp";
import { useTranslations } from "next-intl";
import { useState } from "react";
import {
  ConfirmDialog,
  InlineError,
  SettingsSection,
  settingsButtonClass,
  settingsInputClass,
  useAsyncAction,
} from "../../../components/settings-ui";

const TOTP_PERIOD_SECONDS = 30;
const TOTP_DIGITS = 6;

type Enrollment = { readonly secret: Uint8Array; readonly qrCodeUrl: string };

/** Build the otpauth QR code exactly as Hexclave's MFA section does. */
export async function totpQrCode(
  issuer: string,
  account: string,
  secret: Uint8Array,
): Promise<string> {
  const QRCode = await import("qrcode");
  const uri = createTOTPKeyURI(issuer, account, secret, TOTP_PERIOD_SECONDS, TOTP_DIGITS);
  return QRCode.toDataURL(uri);
}

/** TOTP multi-factor authentication: enroll with a QR code, or disable. */
export function MfaSection({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.auth.mfa");
  const project = useStackApp().useProject();
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [confirmingDisable, setConfirmingDisable] = useState(false);
  const [run, state] = useAsyncAction(t("startError"));
  const enabled = user.isMultiFactorRequired;

  const start = () =>
    run(async () => {
      const secret = crypto.getRandomValues(new Uint8Array(20));
      const qrCodeUrl = await totpQrCode(project.displayName, user.primaryEmail ?? user.id, secret);
      setEnrollment({ secret, qrCodeUrl });
    });

  return (
    <SettingsSection title={t("title")} description={enabled ? t("enabledDescription") : t("disabledDescription")}>
      {!enabled && enrollment ? (
        <MfaEnrollment
          user={user}
          enrollment={enrollment}
          onFinish={() => setEnrollment(null)}
        />
      ) : null}
      {enabled ? (
        <button type="button" onClick={() => setConfirmingDisable(true)} className={settingsButtonClass("secondary", "sm")}>
          {t("disable")}
        </button>
      ) : !enrollment ? (
        <button type="button" disabled={state.pending} onClick={() => void start()} className={settingsButtonClass("secondary", "sm")}>
          {t("enable")}
        </button>
      ) : null}
      <InlineError message={state.error} />
      <ConfirmDialog
        open={confirmingDisable}
        onOpenChange={setConfirmingDisable}
        title={t("disableTitle")}
        description={t("disableBody")}
        confirmLabel={t("disableConfirm")}
        errorMessage={t("disableError")}
        onConfirm={() => user.update({ totpMultiFactorSecret: null })}
      />
    </SettingsSection>
  );
}

function MfaEnrollment({
  user,
  enrollment,
  onFinish,
}: {
  readonly user: CurrentUser;
  readonly enrollment: Enrollment;
  readonly onFinish: () => void;
}) {
  const t = useTranslations("dashboard.settings.auth.mfa");
  const [code, setCode] = useState("");
  const [wrong, setWrong] = useState(false);
  const [run, state] = useAsyncAction(t("enableError"));

  // Hexclave verified in an effect on every keystroke; the change handler
  // does the same work without an effect.
  const submitIfValid = async (value: string) => {
    if (value.length !== TOTP_DIGITS) return;
    if (!verifyTOTP(enrollment.secret, TOTP_PERIOD_SECONDS, TOTP_DIGITS, value)) {
      setWrong(true);
      return;
    }
    const ok = await run(() => user.update({ totpMultiFactorSecret: enrollment.secret }));
    if (ok) onFinish();
  };

  return (
    <div className="flex flex-col gap-2 sm:items-end">
      <p className="text-xs">{t("scan")}</p>
      {/* eslint-disable-next-line @next/next/no-img-element -- local data URL */}
      <img
        width={200}
        height={200}
        src={enrollment.qrCodeUrl}
        alt={t("qrAlt")}
        className="border border-border bg-white p-2"
      />
      <label className="text-xs" htmlFor="mfa-code">{t("enterCode")}</label>
      <input
        id="mfa-code"
        inputMode="numeric"
        autoComplete="one-time-code"
        placeholder="123456"
        maxLength={TOTP_DIGITS}
        value={code}
        disabled={state.pending}
        onChange={(event) => {
          const value = event.target.value.replace(/\D/g, "");
          setCode(value);
          setWrong(false);
          void submitIfValid(value);
        }}
        className={`${settingsInputClass} sm:w-40`}
      />
      <InlineError message={wrong ? t("incorrect") : state.error} />
      <button type="button" disabled={state.pending} onClick={onFinish} className={settingsButtonClass("secondary", "sm")}>
        {t("cancel")}
      </button>
    </div>
  );
}
