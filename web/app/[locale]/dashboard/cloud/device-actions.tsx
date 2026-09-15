"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import { useRouter } from "@/i18n/navigation";
import { Modal } from "../../components/modal";
import { useState } from "react";

export function CloudDeviceActions({
  id,
  name,
}: {
  readonly id: string;
  readonly name: string;
}) {
  const t = useTranslations("dashboard.cloud");
  const router = useRouter();
  const [renameOpen, setRenameOpen] = useState(false);
  const [revokeOpen, setRevokeOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function rename(formData: FormData) {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch(`/api/vm/access-grants/${encodeURIComponent(id)}`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ displayName: formData.get("displayName") }),
      });
      if (!response.ok) throw new Error();
      setRenameOpen(false);
      router.refresh();
    } catch {
      setError(t("renameError"));
    } finally {
      setBusy(false);
    }
  }

  async function revoke() {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch(`/api/vm/access-grants/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
      if (!response.ok) throw new Error();
      setRevokeOpen(false);
      router.refresh();
    } catch {
      setError(t("revokeError"));
    } finally {
      setBusy(false);
    }
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
