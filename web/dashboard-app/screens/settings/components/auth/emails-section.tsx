"use client";

import type { ContactChannel, CurrentUser } from "@hexclave/next";
import { type SettingsEmail, useRefreshSettings } from "@/dashboard-app/queries/settings";
import { KnownErrors } from "@hexclave/shared";
import { useTranslations } from "next-intl";
import { useState } from "react";
import {
  ActionMenu,
  Badge,
  ConfirmDialog,
  InlineError,
  SettingsPanel,
  settingsButtonClass,
  settingsInputClass,
  useAsyncAction,
  type ActionMenuItem,
} from "@/dashboard-app/components/settings-ui";
import {
  emailRowActions,
  isLastSignInEmail,
  sortEmailChannels,
  validateNewEmail,
  type EmailRowAction,
} from "../../lib/contact-channels";

type RowActionRunner = (action: () => Promise<void>) => Promise<boolean>;

/** The SDK contact channel `id`, so a write runs with Hexclave's user-level rules. */
async function contactChannel(user: CurrentUser, id: string): Promise<ContactChannel> {
  const channel = (await user.listContactChannels()).find((candidate) => candidate.id === id);
  if (!channel) throw new Error("contact_channel_not_found");
  return channel;
}

/** Emails table with add, verify, primary, sign-in and remove actions. */
export function EmailsSection({
  user,
  channels,
}: {
  readonly user: CurrentUser;
  readonly channels: readonly SettingsEmail[];
}) {
  const t = useTranslations("dashboard.settings.auth.emails");
  const refresh = useRefreshSettings();
  const onChannel = (id: string, write: (channel: ContactChannel) => Promise<void>) => async () => {
    await write(await contactChannel(user, id));
    await refresh();
  };
  const emails = sortEmailChannels(channels);
  const lastSignInEmail = isLastSignInEmail(channels);
  const [adding, setAdding] = useState(channels.length === 0);
  const [removing, setRemoving] = useState<SettingsEmail | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [runRowAction, rowState] = useAsyncAction(t("actionError"), (error) =>
    KnownErrors.ContactChannelAlreadyUsedForAuthBySomeoneElse.isInstance(error)
      ? t("usedBySomeoneElse")
      : null,
  );

  return (
    <SettingsPanel
      title={t("title")}
      description={t("description")}
      actions={
        adding ? null : (
          <button type="button" onClick={() => setAdding(true)} className={settingsButtonClass("secondary", "sm")}>
            {t("add")}
          </button>
        )
      }
    >
      {adding ? (
        <AddEmailForm
          user={user}
          channels={channels}
          onDone={(message) => {
            setAdding(false);
            setNotice(message);
            void refresh();
          }}
          onCancel={() => setAdding(false)}
        />
      ) : null}
      {emails.length > 0 ? (
        <ul className="divide-y divide-border border border-border">
          {emails.map((channel) => (
            <EmailRow
              key={channel.id}
              channel={channel}
              actions={emailRowActions(channel, lastSignInEmail)}
              pending={rowState.pending}
              run={runRowAction}
              onChannel={onChannel}
              onNotice={setNotice}
              onRemove={() => setRemoving(channel)}
            />
          ))}
        </ul>
      ) : null}
      <InlineError message={rowState.error} />
      {notice ? <p role="status" className="text-xs text-muted">{notice}</p> : null}
      <ConfirmDialog
        open={removing !== null}
        onOpenChange={(open) => {
          if (!open) setRemoving(null);
        }}
        title={t("removeTitle")}
        description={t("removeBody", { email: removing?.value ?? "" })}
        confirmLabel={t("remove")}
        errorMessage={t("actionError")}
        onConfirm={async () => {
          if (removing) await onChannel(removing.id, (channel) => channel.delete())();
        }}
      />
    </SettingsPanel>
  );
}

function AddEmailForm({
  user,
  channels,
  onDone,
  onCancel,
}: {
  readonly user: CurrentUser;
  readonly channels: readonly SettingsEmail[];
  readonly onDone: (notice: string) => void;
  readonly onCancel: () => void;
}) {
  const t = useTranslations("dashboard.settings.auth.emails");
  const [value, setValue] = useState("");
  const [run, state] = useAsyncAction(t("addError"));

  const submit = async () => {
    const problem = validateNewEmail(value, channels);
    if (problem) {
      state.setError(t(`validation.${problem}`));
      return;
    }
    const email = value.trim();
    let verificationFailed = false;
    const ok = await run(async () => {
      const created = await user.createContactChannel({ type: "email", value: email, usedForAuth: false });
      if (created.isVerified) return;
      try {
        await created.sendVerificationEmail();
      } catch {
        verificationFailed = true;
      }
    });
    if (ok) onDone(verificationFailed ? t("addedVerificationFailed", { email }) : t("added", { email }));
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-1"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <div className="flex flex-col gap-2 sm:flex-row">
        <input
          type="email"
          autoFocus
          aria-label={t("inputLabel")}
          placeholder={t("placeholder")}
          value={value}
          disabled={state.pending}
          onChange={(event) => {
            setValue(event.target.value);
            state.clearError();
          }}
          className={settingsInputClass}
        />
        <div className="flex gap-2">
          <button type="submit" disabled={state.pending} className={settingsButtonClass("primary", "sm")}>
            {state.pending ? t("adding") : t("addSubmit")}
          </button>
          <button type="button" disabled={state.pending} onClick={onCancel} className={settingsButtonClass("secondary", "sm")}>
            {t("cancel")}
          </button>
        </div>
      </div>
      <InlineError message={state.error} />
    </form>
  );
}

function EmailRow({
  channel,
  actions,
  pending,
  run,
  onChannel,
  onNotice,
  onRemove,
}: {
  readonly channel: SettingsEmail;
  readonly actions: readonly EmailRowAction[];
  readonly pending: boolean;
  readonly run: RowActionRunner;
  readonly onChannel: (id: string, write: (channel: ContactChannel) => Promise<void>) => () => Promise<void>;
  readonly onNotice: (notice: string | null) => void;
  readonly onRemove: () => void;
}) {
  const t = useTranslations("dashboard.settings.auth.emails");
  const handlers: Record<EmailRowAction["kind"], () => void> = {
    sendVerification: () => {
      onNotice(null);
      void run(onChannel(channel.id, (sdk) => sdk.sendVerificationEmail())).then((ok) => {
        if (ok) onNotice(t("verificationSent", { email: channel.value }));
      });
    },
    setPrimary: () => void run(onChannel(channel.id, (sdk) => sdk.update({ isPrimary: true }))),
    useForSignIn: () => void run(onChannel(channel.id, (sdk) => sdk.update({ usedForAuth: true }))),
    stopUsingForSignIn: () => void run(onChannel(channel.id, (sdk) => sdk.update({ usedForAuth: false }))),
    remove: onRemove,
  };
  const items: ActionMenuItem[] = actions.map((action) => ({
    id: action.kind,
    label: t(`actions.${action.kind}`),
    onSelect: handlers[action.kind],
    disabled: action.disabledReason !== undefined,
    disabledReason: action.disabledReason ? t(`disabled.${action.disabledReason}`) : undefined,
    danger: action.kind === "remove",
  }));

  return (
    <li className="flex items-center justify-between gap-3 px-3 py-2">
      <div className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
        <span className="min-w-0 truncate">{channel.value}</span>
        <span className="flex flex-wrap gap-1.5">
          {channel.isPrimary ? <Badge>{t("badges.primary")}</Badge> : null}
          {!channel.isVerified ? <Badge tone="danger">{t("badges.unverified")}</Badge> : null}
          {channel.usedForAuth ? <Badge tone="outline">{t("badges.usedForSignIn")}</Badge> : null}
        </span>
      </div>
      <ActionMenu label={t("actionsLabel", { email: channel.value })} items={items} disabled={pending} />
    </li>
  );
}
