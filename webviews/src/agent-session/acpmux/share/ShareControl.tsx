// The Share dialog's host. The chat's ••• menu opens it with Share… (Leo, 2026-11-07: "Actually
// wait, would that defeat the minimalism? I think it kind of would, wouldn't it? I think you'd want
// to put it in the dot dot dot area."), so the header gains no button. Copy link puts the link on
// the clipboard and says so in a toast with Manage links (Settings > Shared links).
//
// Every step is the daemon's (`share.op` through the host, shareState.ts): the dialog re-reads the
// chat's shares after each one, so what it shows is what the daemon holds. No timer and no
// observer: the dialog reads on open and after a step; the toast queue arms its one timeout only
// while a toast shows (NoticeStack.tsx).
import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { Dialog } from "../../../ui/Dialog";
import { NoticeStack, createNoticeQueue } from "../../../ui/NoticeStack";
import { useT, translate } from "../i18n";
import { copyTextResult } from "../conversation/clipboard";
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
  if (code === "share.restrict_raced") return translate("share.error.restrictRaced");
  const message = (error as { message?: unknown } | undefined)?.message;
  return typeof message === "string" && message ? message : translate("share.error.generic");
}

export function ShareDialogHost({
  sessionId,
  chat,
  open,
  onOpenChange,
  call,
  initial,
}: {
  sessionId: string;
  chat: string;
  /** Share… in the chat menu sets it; Done, Escape and a press outside clear it. */
  open: boolean;
  onOpenChange(open: boolean): void;
  /** The host's `share.op`; the gallery passes a fixture. */
  call?: ShareCall;
  /** The view drawn before the first read (the gallery). */
  initial?: ShareView;
}) {
  const t = useT();
  const client = useMemo(() => shareClient(sessionId, call), [sessionId, call]);
  const [view, setView] = useState<ShareView>(initial ?? EMPTY);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  /// The chat's shares have been read since this host mounted: until then every step waits, so a
  /// step never acts on another chat's view (App keys this host by the chat's session).
  const [loaded, setLoaded] = useState(initial !== undefined);

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
  // Each open reads the chat's shares afresh: what the dialog shows is what the daemon holds now.
  useEffect(() => {
    if (!open) return;
    let current = true;
    setStatus(null);
    client.state().then(
      (next) => {
        if (!current) return;
        setView(next);
        setLoaded(true);
      },
      (error: unknown) => current && setStatus(failure(error)),
    );
    return () => {
      current = false;
    };
  }, [open, client]);
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
      <Dialog
        open={open}
        onOpenChange={onOpenChange}
        label={t("share.title", { chat })}
        className="ui-glass ui-glass-floats share-dialog-popup"
      >
        <ShareDialogBody
          chat={chat}
          view={view}
          status={status}
          busy={busy || !loaded}
          onInvite={(account: string, role: ShareRole) => void step(() => client.invite(account, role))}
          onRole={(account: string, role: ShareRole) => void step(() => client.setRole(account, role))}
          onRemove={(account: string) => void step(() => client.remove(account))}
          onGeneral={general}
          onCopy={copy}
          onDone={() => onOpenChange(false)}
        />
      </Dialog>
      {/* Over the page, not the header: the header is a positioned row, so the stack's bottom
          would resolve against it and clip. */}
      {createPortal(<NoticeStack queue={shareToasts} dismissLabel={t("share.dismiss")} />, document.body)}
    </>
  );
}
