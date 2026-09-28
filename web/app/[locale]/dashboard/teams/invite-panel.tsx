"use client";

import { useFormatter, useTranslations } from "next-intl";
import { useState } from "react";
import { ConfirmDialog } from "../components/settings-ui/confirm-dialog";
import { InlineError } from "../components/settings-ui/feedback";
import { settingsButtonClass, settingsInputClass, settingsLabelClass } from "../components/settings-ui/styles";
import {
  type InviteResult,
  type TeamInviteLink,
  type TeamRole,
  useCreateLink,
  useInviteMembers,
  useRevokeLink,
} from "./team-api";
import {
  addEmailChips,
  type EmailChip,
  expiresInDays,
  INVITE_LINK_EXPIRY_OPTIONS,
  type InviteLinkExpiryOption,
  MAX_INVITE_EMAILS,
  parseMaxUses,
  removeEmailChip,
  sendableEmails,
} from "./team-logic";
import { CopyValueButton, useTeamErrorText } from "./team-ui";

const COMMIT_KEYS = new Set(["Enter", ",", ";", " ", "Tab"]);

/**
 * Multi-address input. Typing a separator, pasting a list, or leaving the
 * field turns text into chips; invalid chips stay visible and block sending.
 */
export function EmailChipInput({
  chips,
  onChange,
  disabled = false,
}: {
  readonly chips: readonly EmailChip[];
  readonly onChange: (chips: readonly EmailChip[], overflow: number) => void;
  readonly disabled?: boolean;
}) {
  const t = useTranslations("dashboard.teams.invite");
  const [draft, setDraft] = useState("");

  const commit = (raw: string) => {
    if (!raw.trim()) return;
    const update = addEmailChips(chips, raw);
    onChange(update.chips, update.overflow);
    setDraft("");
  };

  return (
    <div className="flex min-h-9 flex-wrap items-center gap-1 border border-border bg-background px-1.5 py-1 focus-within:outline focus-within:outline-1 focus-within:outline-foreground">
      {chips.map((chip) => (
        <span
          key={chip.email}
          className={`inline-flex items-center gap-1 border px-1.5 py-0.5 text-xs ${
            chip.valid ? "border-border bg-code-bg" : "border-red-600/60 text-red-600 dark:text-red-400"
          }`}
          title={chip.valid ? undefined : t("invalidEmail")}
        >
          {chip.email}
          <button
            type="button"
            aria-label={t("removeEmail", { email: chip.email })}
            disabled={disabled}
            onClick={() => onChange(removeEmailChip(chips, chip.email), 0)}
            className="text-muted hover:text-foreground"
          >
            ×
          </button>
        </span>
      ))}
      <input
        value={draft}
        disabled={disabled}
        aria-label={t("emailsLabel")}
        placeholder={chips.length === 0 ? t("emailsPlaceholder") : ""}
        onChange={(event) => setDraft(event.target.value)}
        onPaste={(event) => {
          const text = event.clipboardData.getData("text");
          if (!/[\s,;]/.test(text)) return;
          event.preventDefault();
          commit(`${draft} ${text}`);
        }}
        onKeyDown={(event) => {
          if (COMMIT_KEYS.has(event.key) && draft.trim()) {
            event.preventDefault();
            commit(draft);
          } else if (event.key === "Backspace" && draft === "" && chips.length > 0) {
            onChange(chips.slice(0, -1), 0);
          }
        }}
        onBlur={() => commit(draft)}
        className="min-w-40 flex-1 bg-transparent px-1 py-0.5 text-sm outline-none"
      />
    </div>
  );
}

export function InviteMembersForm({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.teams.invite");
  const errorText = useTeamErrorText();
  const invite = useInviteMembers(teamId);
  const [chips, setChips] = useState<readonly EmailChip[]>([]);
  const [overflow, setOverflow] = useState(0);
  const [role, setRole] = useState<TeamRole>("member");
  const [result, setResult] = useState<InviteResult | null>(null);

  const emails = sendableEmails(chips);
  const invalidCount = chips.filter((chip) => !chip.valid).length;

  const send = () => {
    if (!emails) return;
    setResult(null);
    invite.mutate(
      { emails, role },
      {
        onSuccess: (response) => {
          setResult(response);
          // Keep only the failed addresses so they can be fixed and resent.
          const failed = new Set(response.failed.map((failure) => failure.email.toLowerCase()));
          setChips(chips.filter((chip) => failed.has(chip.email.toLowerCase())));
          setOverflow(0);
        },
      },
    );
  };

  return (
    <form
      className="grid gap-2"
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <EmailChipInput
        chips={chips}
        disabled={invite.isPending}
        onChange={(next, dropped) => {
          setChips(next);
          setOverflow(dropped);
          setResult(null);
        }}
      />
      <div className="flex flex-wrap items-center gap-2">
        <label className="flex items-center gap-2 text-xs text-muted">
          {t("roleLabel")}
          <select
            value={role}
            onChange={(event) => setRole(event.target.value === "admin" ? "admin" : "member")}
            className={`${settingsInputClass} w-auto`}
          >
            <option value="member">{t("roleMember")}</option>
            <option value="admin">{t("roleAdmin")}</option>
          </select>
        </label>
        <span className="font-mono text-[11px] text-muted">
          {t("count", { count: chips.length, max: MAX_INVITE_EMAILS })}
        </span>
        <button type="submit" disabled={!emails || invite.isPending} className={`${settingsButtonClass("primary")} ml-auto`}>
          {invite.isPending ? t("sending") : t("send")}
        </button>
      </div>
      {invalidCount > 0 ? <InlineError message={t("invalidCount", { count: invalidCount })} /> : null}
      {overflow > 0 ? <InlineError message={t("overflow", { count: overflow, max: MAX_INVITE_EMAILS })} /> : null}
      {invite.isError ? <InlineError message={errorText(invite.error)} /> : null}
      {result ? <InviteResultSummary result={result} /> : null}
    </form>
  );
}

function InviteResultSummary({ result }: { readonly result: InviteResult }) {
  const t = useTranslations("dashboard.teams.invite");
  const failures = useTranslations("dashboard.teams.inviteFailure");
  return (
    <div role="status" className="grid gap-1 border border-border p-2 text-xs">
      {result.invitations.length > 0 ? <p>{t("sent", { count: result.invitations.length })}</p> : null}
      {result.failed.length > 0 ? (
        <ul className="grid gap-0.5 text-red-600 dark:text-red-400">
          {result.failed.map((failure) => (
            <li key={failure.email}>
              {failure.email}: {failures.has(failure.code) ? failures(failure.code) : failures("generic")}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

export function InviteLinkCreator({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.teams.links");
  const errorText = useTeamErrorText();
  const create = useCreateLink(teamId);
  const [expiry, setExpiry] = useState<InviteLinkExpiryOption>("7");
  const [maxUses, setMaxUses] = useState("");
  const [maxUsesInvalid, setMaxUsesInvalid] = useState(false);
  const [createdUrl, setCreatedUrl] = useState<string | null>(null);

  return (
    <div className="grid gap-2">
      <form
        className="flex flex-wrap items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault();
          const parsed = parseMaxUses(maxUses);
          setMaxUsesInvalid(!parsed.ok);
          if (!parsed.ok) return;
          setCreatedUrl(null);
          create.mutate(
            { expiresInDays: expiresInDays(expiry), maxUses: parsed.value },
            { onSuccess: ({ url }) => setCreatedUrl(url) },
          );
        }}
      >
        <label>
          <span className={settingsLabelClass}>{t("expiryLabel")}</span>
          <select
            value={expiry}
            onChange={(event) => setExpiry(event.target.value as InviteLinkExpiryOption)}
            className={`${settingsInputClass} mt-1 w-auto`}
          >
            {INVITE_LINK_EXPIRY_OPTIONS.map((option) => (
              <option key={option} value={option}>
                {t(`expiry.${option}`)}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span className={settingsLabelClass}>{t("maxUsesLabel")}</span>
          <input
            value={maxUses}
            inputMode="numeric"
            placeholder={t("maxUsesPlaceholder")}
            onChange={(event) => setMaxUses(event.target.value)}
            className={`${settingsInputClass} mt-1 w-32`}
          />
        </label>
        <button type="submit" disabled={create.isPending} className={settingsButtonClass("secondary")}>
          {create.isPending ? t("creating") : t("create")}
        </button>
      </form>
      <p className="text-xs text-muted">{t("memberOnly")}</p>
      {maxUsesInvalid ? <InlineError message={t("maxUsesInvalid")} /> : null}
      {create.isError ? <InlineError message={errorText(create.error)} /> : null}
      {createdUrl ? (
        <div className="grid gap-1 border border-foreground p-2">
          <p className="text-xs text-muted">{t("showOnce")}</p>
          <div className="flex flex-wrap items-center gap-2">
            <code className="min-w-0 flex-1 break-all font-mono text-xs">{createdUrl}</code>
            <CopyValueButton value={createdUrl} />
          </div>
        </div>
      ) : null}
    </div>
  );
}

export function InviteLinksTable({
  teamId,
  links,
}: {
  readonly teamId: string;
  readonly links: readonly TeamInviteLink[];
}) {
  const t = useTranslations("dashboard.teams.links");
  const format = useFormatter();
  const errorText = useTeamErrorText();
  // Revocation lives at the table level: the optimistic update unmounts the
  // row, and a failure must still be reported when it comes back.
  const revoke = useRevokeLink(teamId);
  const [revoking, setRevoking] = useState<string | null>(null);
  return (
    <div className="grid gap-1">
      {links.length === 0 ? (
        <p className="text-xs text-muted">{t("empty")}</p>
      ) : (
        <ul className="divide-y divide-border border border-border">
          {links.map((link) => (
            <li key={link.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 px-3 py-2 text-xs">
              <span>{t("createdAt", { at: format.dateTime(new Date(link.createdAt), { dateStyle: "medium" }) })}</span>
              <span className="text-muted">
                {link.expiresAt
                  ? t("expiresAt", { at: format.dateTime(new Date(link.expiresAt), { dateStyle: "medium" }) })
                  : t("neverExpires")}
              </span>
              <span className="font-mono text-muted">
                {link.maxUses === null
                  ? t("usesUnlimited", { count: link.useCount })
                  : t("uses", { count: link.useCount, max: link.maxUses })}
              </span>
              <button
                type="button"
                className={`${settingsButtonClass("secondary", "sm")} ml-auto`}
                onClick={() => setRevoking(link.id)}
              >
                {t("revoke")}
              </button>
            </li>
          ))}
        </ul>
      )}
      {revoke.isError ? <InlineError message={errorText(revoke.error)} /> : null}
      <ConfirmDialog
        open={revoking !== null}
        onOpenChange={(open) => {
          if (!open) setRevoking(null);
        }}
        title={t("revokeTitle")}
        description={t("revokeBody")}
        confirmLabel={t("revoke")}
        onConfirm={async () => {
          // Optimistic: close now; the row returns with an inline error on failure.
          if (revoking) revoke.mutate(revoking);
        }}
      />
    </div>
  );
}
