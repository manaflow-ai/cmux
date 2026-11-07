// The chat header's Share control (Leo, 2026-11-07: "the Figma and the Google Docs, like the
// collaborators thing ... at the top bar area section, the top right"): who has the chat open as
// overlapping faces, then Share, which opens the Share dialog. Copy link puts the link on the
// clipboard and says so in a toast with Manage links (Settings > Shared links).
//
// Every step is the daemon's (`share.op` through the host, shareState.ts): the dialog re-reads the
// chat's shares after each one, so what it shows is what the daemon holds. No timer and no
// observer: the dialog reads on open and after a step; the toast queue arms its one timeout only
// while a toast shows (NoticeStack.tsx).
import { useMemo, useState } from "react";
import { Dialog } from "../../../ui/Dialog";
import { NoticeStack, createNoticeQueue } from "../../../ui/NoticeStack";
import { useT, translate } from "../i18n";
import { copyTextResult } from "../conversation/clipboard";
import { tooltipProps } from "../shortcuts";
import { HeaderIcon } from "../header/HeaderIcon";
import { ShareDialogBody } from "./ShareDialog";
import {
  shareClient,
  shareView,
  type GeneralAccess,
  type ShareCall,
  type ShareRole,
  type ShareView,
} from "./shareState";
import "./share.css";

/** The pane's share toasts (one queue per page; the header owns one Share control at a time). */
export const shareToasts = createNoticeQueue(1);

const EMPTY: ShareView = shareView([]);

/** A daemon refusal's line for the dialog's status. */
function failure(error: unknown): string {
  const code = (error as { code?: unknown } | undefined)?.code ?? (error as Error | undefined)?.message;
  if (code === "share.no_room") return translate("share.error.noRoom");
  if (code === "share.needs_sign_in") return translate("share.error.signIn");
  if (code === "gesture_required") return translate("share.error.gesture");
  const message = (error as { message?: unknown } | undefined)?.message;
  return typeof message === "string" && message ? message : translate("share.error.generic");
}

/// How Share draws in the header: the toolbar's 24px glyph (the pick: it fits the tool row's pitch
/// and no-resting-fill rule, design/chat-header.md), the glyph with its word, or Docs' filled button.
export type ShareLook = "icon" | "label" | "filled";

export function ShareButton({
  sessionId,
  chat,
  call,
  initial,
  look = "icon",
}: {
  sessionId: string;
  chat: string;
  /** The host's `share.op`; the gallery passes a fixture. */
  call?: ShareCall;
  /** Open on first draw with this view (the gallery). */
  initial?: ShareView;
  look?: ShareLook;
}) {
  const t = useT();
  const client = useMemo(() => shareClient(sessionId, call), [sessionId, call]);
  const [open, setOpen] = useState(initial !== undefined);
  const [view, setView] = useState<ShareView>(initial ?? EMPTY);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const reload = async () => {
    try {
      setView(await client.state());
    } catch (error) {
      setStatus(failure(error));
    }
  };
  const step = async (work: () => Promise<unknown>) => {
    setBusy(true);
    const failed = await work().then(
      () => null,
      (error: unknown) => failure(error),
    );
    setStatus(failed);
    await reload();
    setBusy(false);
  };
  const openDialog = () => {
    setStatus(null);
    setOpen(true);
    void reload();
  };
  const copy = () =>
    void step(async () => {
      // Restricted copies the invite link (only invited people get in); Anyone copies the viewer link.
      const url = view.general === "anyone" ? await client.viewerLink(view) : view.inviteUrl;
      if (!url || !(await copyTextResult(url))) throw new Error(translate("share.error.copy"));
      shareToasts.show({
        id: "share.copied",
        title: translate(view.general === "anyone" ? "share.toast.public" : "share.toast.invite"),
        message: translate(view.general === "anyone" ? "share.toast.publicDetail" : "share.toast.inviteDetail"),
        actions: [{ id: "manage", label: translate("share.manageLinks"), onSelect: () => void client.manage() }],
      });
    });
  const general = (access: GeneralAccess) =>
    void step(async () => {
      if (access === view.general) return;
      if (access === "anyone") await client.viewerLink(view);
      else await client.restrict(view);
    });
  return (
    <>
      <button
        type="button"
        className="acpmux-header-tool share-button"
        data-quick-action="share"
        data-look={look}
        aria-label={t("share.button")}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...(look === "icon" ? tooltipProps(t("share.button"), undefined) : {})}
        onClick={openDialog}
      >
        <HeaderIcon name="action.share" selected={open} />
        {look !== "icon" && <span className="share-button__label">{t("share.button")}</span>}
      </button>
      <Dialog open={open} onOpenChange={setOpen} label={t("share.title", { chat })} className="share-dialog-popup">
        <ShareDialogBody
          chat={chat}
          view={view}
          status={status}
          busy={busy}
          onInvite={(account: string, role: ShareRole) => void step(() => client.invite(account, role))}
          onRole={(account: string, role: ShareRole) => void step(() => client.setRole(account, role))}
          onRemove={(account: string) => void step(() => client.remove(account))}
          onGeneral={general}
          onCopy={copy}
          onDone={() => setOpen(false)}
        />
      </Dialog>
      <NoticeStack queue={shareToasts} dismissLabel={t("share.dismiss")} />
    </>
  );
}
