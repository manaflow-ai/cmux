// Settings > Server > This Mac on Your Tailnet: sign this Mac's own tailnet node in and out. acpmux runs
// the node (tailnet/embedded.rs) and admits only the owner on every stream it serves, so the card has no
// access switch. The app relays each step on its person connection (SettingsPageProvider `tailnet`); the
// page decides what to show. Sign In starts the node; one that needs a login offers the sign-in page as a
// link the person opens. acpmux answers Sign In before its node says where it got to, so the card reads the
// state again a few times after it (TAILNET_SETTLE_WAITS_MS, about 8 s at most) until it settles; it also
// reads it when the window comes back while a sign-in waits on the browser or an admin. It never polls
// beyond that. A step nobody answered shows acpmux's own state when it has one, or says it got no answer. Hidden where acpmux has no tailnet.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { TAILNET_KEY, tailnetQuery } from "../sectionQueries";
import { t } from "../strings";
import { TAILNET_SETTLE_WAITS_MS, tailnetSettling, tailnetView, tailnetWaits, type TailnetView } from "../tailnet";
import { ActionRow } from "./ActionRow";

export type TailnetVerb = "start" | "login" | "logout";
/** `row` ships (settings.tailnet-layouts holds the others): the state over its detail, actions on the trailing edge. */
export type TailnetLayout = "row" | "stacked" | "split";

/** The row's title, its detail line and its actions for one state. */
function parts(view: TailnetView, busy: boolean, onStep: (verb: TailnetVerb) => void) {
  const action = (verb: TailnetVerb, label: string) => (
    <Button key={verb} className="button" data-tailnet-action={verb} disabled={busy} onClick={() => onStep(verb)}>
      {label}
    </Button>
  );
  const cancel = action("logout", t("settingsPage.cancel"));
  const signedOutHelp = t("settingsPage.tailnet.signedOutHelp");
  switch (view.kind) {
    case "signedOut":
      return {
        title: t("settingsPage.tailnet.signedOut"),
        help: signedOutHelp,
        actions: [action("start", t("settingsPage.tailnet.signIn"))],
      };
    case "starting":
      // Brief, and a Cancel here would be Sign Out, which drops a saved login: no action.
      return { title: t("settingsPage.tailnet.starting"), help: signedOutHelp, actions: [] };
    case "needsLogin":
      return {
        title: t("settingsPage.tailnet.needsLogin"),
        help: t("settingsPage.tailnet.needsLoginHelp"),
        actions: [
          view.url ? (
            <Button
              key="page"
              className="button"
              variant="solid"
              nativeButton={false}
              render={
                <a href={view.url} aria-label={t("settingsPage.tailnet.openSignIn")} data-tailnet-sign-in-page="" />
              }
            >
              {t("settingsPage.tailnet.openSignIn")}
            </Button>
          ) : (
            action("login", t("settingsPage.tailnet.signIn"))
          ),
          cancel,
        ],
      };
    case "approval":
      return {
        title: t("settingsPage.tailnet.approval"),
        help: t("settingsPage.tailnet.approvalHelp"),
        actions: [cancel],
      };
    case "signedIn":
      return {
        title: t("settingsPage.tailnet.signedIn"),
        help: view.address,
        actions: [action("logout", t("settingsPage.tailnet.signOut"))],
      };
    case "error":
      return {
        title: t("settingsPage.tailnet.error"),
        help: view.message,
        actions: [action("start", t("settingsPage.tailnet.tryAgain"))],
      };
  }
}

/** The card's rows for one state, in one of the layouts. */
export function TailnetRows({
  view,
  busy,
  onStep,
  failed = false,
  layout = "row",
}: {
  view: TailnetView;
  busy: boolean;
  onStep: (verb: TailnetVerb) => void;
  /** The last step got no answer from acpmux: the detail line says so instead. */
  failed?: boolean;
  layout?: TailnetLayout;
}) {
  const shown = parts(view, busy, onStep);
  const { title, actions } = shown;
  const help = failed ? t("settingsPage.tailnet.unreachable") : shown.help;
  if (layout === "stacked")
    return (
      <div className="row" data-tailnet-layout="stacked">
        <div className="row-main">
          <div className="row-label">
            <div className="row-title">{title}</div>
            {help && <div className="row-help">{help}</div>}
            <div className="accounts-buttons">{actions}</div>
          </div>
        </div>
      </div>
    );
  if (layout === "split")
    return (
      <>
        <ActionRow title={title} help={help}>
          {null}
        </ActionRow>
        <ActionRow title="" help="">
          {actions}
        </ActionRow>
      </>
    );
  return (
    <ActionRow title={title} help={help}>
      {actions}
    </ActionRow>
  );
}

export function TailnetCard() {
  const store = useStore();
  const client = useQueryClient();
  const query = useQuery(tailnetQuery(store));
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const mounted = useRef(true);
  useEffect(
    () => () => {
      mounted.current = false;
    },
    [],
  );
  const state = query.data ?? null;
  const view = state ? tailnetView(state) : null;
  const waits = view !== null && tailnetWaits(view);
  useEffect(() => {
    if (!waits) return;
    const refresh = () => {
      if (document.visibilityState === "visible") void client.invalidateQueries({ queryKey: TAILNET_KEY });
    };
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [waits, client]);
  if (!view) return null;
  const step = async (verb: TailnetVerb) => {
    setBusy(true);
    setFailed(false);
    try {
      let next = await store.tailnet(verb);
      for (const wait of verb === "logout" ? [] : TAILNET_SETTLE_WAITS_MS) {
        if (!next || !tailnetSettling(next) || !mounted.current) break;
        client.setQueryData(TAILNET_KEY, next);
        await new Promise((resolve) => setTimeout(resolve, wait));
        // A read with no answer keeps what the card has and reads again at the next wait.
        next = (await store.tailnet("state")) ?? next;
      }
      // A Sign In with no answer: acpmux may still hold the reason (its `error` state), so show that if it
      // has one; any other state would hide the failure. Not after Sign Out, where a read could show the
      // old signed-in state as if nothing had been asked.
      if (!next && verb !== "logout" && mounted.current) {
        const now = await store.tailnet("state");
        if (now?.state === "error") next = now;
      }
      // A card that went away writes nothing: the cache may already hold a newer card's state.
      if (!mounted.current) return;
      if (next) client.setQueryData(TAILNET_KEY, next);
      else setFailed(true);
    } finally {
      if (mounted.current) setBusy(false);
    }
  };
  return (
    <section className="group" data-card="tailnet" data-tailnet-state={view.kind}>
      <h3 className="group-title">{t("settingsPage.tailnet.title")}</h3>
      <div className="rows">
        <TailnetRows view={view} busy={busy} failed={failed} onStep={(verb) => void step(verb)} />
      </div>
    </section>
  );
}
