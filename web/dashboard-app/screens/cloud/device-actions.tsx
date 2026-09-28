"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { Modal } from "@/app/[locale]/components/modal";
import { cloudDevicesQuery } from "../../queries/cloud";

type DeviceAction =
  | { readonly kind: "rename"; readonly displayName: FormDataEntryValue | null }
  | { readonly kind: "revoke" };

async function sendDeviceAction(id: string, action: DeviceAction): Promise<void> {
  const url = `/api/vm/access-grants/${encodeURIComponent(id)}`;
  const response = action.kind === "rename"
    ? await fetch(url, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ displayName: action.displayName }),
    })
    : await fetch(url, { method: "DELETE" });
  if (!response.ok) throw new Error(`${action.kind} failed`);
}

export function CloudDeviceActions({
  id,
  name,
}: {
  readonly id: string;
  readonly name: string;
}) {
  const t = useTranslations("dashboard.cloud");
  const queryClient = useQueryClient();
  const [renameOpen, setRenameOpen] = useState(false);
  const [revokeOpen, setRevokeOpen] = useState(false);
  const mutation = useMutation({
    mutationFn: (action: DeviceAction) => sendDeviceAction(id, action),
    onSuccess: async (_result, action) => {
      if (action.kind === "rename") setRenameOpen(false);
      else setRevokeOpen(false);
      await queryClient.invalidateQueries({ queryKey: cloudDevicesQuery.queryKey });
    },
  });
  const busy = mutation.isPending;
  const error = mutation.isError
    ? t(mutation.variables.kind === "rename" ? "renameError" : "revokeError")
    : null;

  function rename(formData: FormData) {
    mutation.mutate({ kind: "rename", displayName: formData.get("displayName") });
  }

  function revoke() {
    mutation.mutate({ kind: "revoke" });
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <button className="border border-border px-2 py-1 hover:bg-code-bg" onClick={() => setRenameOpen(true)}>
        {t("rename")}
      </button>
      <button className="border border-border px-2 py-1 hover:bg-code-bg" onClick={() => setRevokeOpen(true)}>
        {t("revoke")}
      </button>
      {error ? <p className="w-full text-xs text-foreground">{error}</p> : null}

      <Modal open={renameOpen} onOpenChange={setRenameOpen}>
        <Dialog.Title className="text-sm font-medium">{t("renameTitle")}</Dialog.Title>
        <form action={rename} className="mt-4 space-y-3">
          <label className="block text-xs text-muted" htmlFor={`device-name-${id}`}>{t("nameLabel")}</label>
          <input
            id={`device-name-${id}`}
            name="displayName"
            defaultValue={name}
            maxLength={63}
            className="w-full border border-border bg-background px-2 py-1.5 text-foreground"
          />
          <div className="flex justify-end gap-2">
            <Dialog.Close className="border border-border px-3 py-1.5">{t("cancel")}</Dialog.Close>
            <button disabled={busy} className="border border-foreground bg-foreground px-3 py-1.5 text-background">
              {t("save")}
            </button>
          </div>
        </form>
      </Modal>

      <Modal open={revokeOpen} onOpenChange={setRevokeOpen}>
        <Dialog.Title className="text-sm font-medium">{t("revokeTitle", { name })}</Dialog.Title>
        <Dialog.Description className="mt-2 text-xs text-muted">{t("revokeBody")}</Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className="border border-border px-3 py-1.5">{t("cancel")}</Dialog.Close>
          <button onClick={revoke} disabled={busy} className="border border-foreground bg-foreground px-3 py-1.5 text-background">
            {t("revoke")}
          </button>
        </div>
      </Modal>
    </div>
  );
}
