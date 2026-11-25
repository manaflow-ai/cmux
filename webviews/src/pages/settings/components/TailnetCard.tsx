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
import { Dialog, DialogDescription, DialogTitle } from "../../../ui/Dialog";
import { useSettingsState, useRowState, useStore } from "../context";
import type { TailnetVMReply } from "../ops";
import { TAILNET_KEY, tailnetQuery } from "../sectionQueries";
import "../tailnetJoin.css";
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
  const settings = useSettingsState();
  const enabled = useRowState("tailnet.join.enabled").value === true;
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
  if (!view && !enabled) return null;
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
    <>
      {view && (
        <section className="group" data-card="tailnet" data-tailnet-state={view.kind}>
          <h3 className="group-title">{t("settingsPage.tailnet.title")}</h3>
          <div className="rows">
            <TailnetRows view={view} busy={busy} failed={failed} onStep={(verb) => void step(verb)} />
          </div>
        </section>
      )}
      {enabled && <TailnetVMCard machines={settings.host?.machines ?? []} />}
    </>
  );
}

function TailnetVMCard({ machines }: { machines: Array<{ id: string; title: string }> }) {
  const store = useStore();
  const loginServer = String(useRowState("tailnet.join.loginServer").value ?? "");
  const hostname = String(useRowState("tailnet.join.hostname").value ?? "");
  const tags =
    (useRowState("tailnet.join.tags").value as unknown[] | undefined)?.filter(
      (v): v is string => typeof v === "string",
    ) ?? [];
  const ssh = useRowState("tailnet.join.ssh").value === true;
  const ephemeral = useRowState("tailnet.join.ephemeral").value === true;
  const servePorts =
    (useRowState("tailnet.join.servePorts").value as unknown[] | undefined)?.filter(
      (v): v is string => typeof v === "string",
    ) ?? [];
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<TailnetVMReply | null>(null);
  const [vm, setVM] = useState("");
  const leave = async () => {
    if (!selected?.vm) return;
    const reply = await store.leaveTailnetVM(selected.vm);
    if (reply.ok) setSelected(null);
  };
  return (
    <section className="group" data-card="tailnet-cloud">
      <h3 className="group-title">{t("settingsPage.tailnet.cloudTitle")}</h3>
      <div className="rows">
        <div className="row">
          <div className="row-label">
            <div className="row-title">{selected?.node?.dnsName ?? t("settingsPage.tailnet.cloudTitle")}</div>
            <div className="row-help">{selected ? tailnetFacts(selected) : t("settingsPage.tailnet.cloudHelp")}</div>
          </div>
          <div className="accounts-buttons">
            {selected ? (
              <Button className="button" data-tailnet-vm-leave="" onClick={() => void leave()}>
                {t("settingsPage.tailnet.leave")}
              </Button>
            ) : (
              <Button className="button" data-tailnet-vm-join="" onClick={() => setOpen(true)}>
                {t("settingsPage.tailnet.join")}
              </Button>
            )}
          </div>
        </div>
      </div>
      {open && (
        <TailnetJoinDialog
          machines={machines}
          vm={vm}
          setVM={setVM}
          options={{ loginServer, hostname, tags, ssh, ephemeral, servePorts }}
          onClose={() => setOpen(false)}
          onJoined={(reply) => {
            setSelected(reply);
            setOpen(false);
          }}
        />
      )}
    </section>
  );
}

function tailnetFacts(reply: TailnetVMReply): string {
  const node = reply.node;
  if (!node) return reply.error ?? "";
  const facts = [
    node.online === false ? t("settingsPage.tailnet.offline") : t("settingsPage.tailnet.online"),
    node.ips?.length ? `${t("settingsPage.tailnet.ips")}: ${node.ips.join(", ")}` : "",
    node.tags?.length ? `${t("settingsPage.tailnet.tags")}: ${node.tags.join(", ")}` : "",
  ].filter(Boolean);
  return facts.join(" · ");
}

/** Tailscale OAuth client secrets and API keys outlive one join; a single-use auth key does not. */
function tailnetKeyLooksReusable(key: string, oauth: boolean): boolean {
  const text = key.trim();
  return oauth || text.startsWith("tskey-client-") || text.startsWith("tskey-api-");
}

function TailnetJoinDialog({
  machines,
  vm,
  setVM,
  options,
  onClose,
  onJoined,
}: {
  machines: Array<{ id: string; title: string }>;
  vm: string;
  setVM: (value: string) => void;
  options: {
    loginServer: string;
    hostname: string;
    tags: string[];
    ssh: boolean;
    ephemeral: boolean;
    servePorts: string[];
  };
  onClose: () => void;
  onJoined: (reply: TailnetVMReply) => void;
}) {
  const store = useStore();
  const [key, setKey] = useState("");
  const [oauth, setOAuth] = useState(false);
  const [switchTailnet, setSwitchTailnet] = useState(false);
  const [allowHttp, setAllowHttp] = useState(false);
  const loginServer = options.loginServer.trim();
  // A plain-http login server sends the key unencrypted: the CLI refuses it without --allow-http,
  // so the person ticks it for this server, in this sheet, every time.
  const plainHttp = /^http:\/\//i.test(loginServer);
  const reusable = tailnetKeyLooksReusable(key, oauth);
  const ready = vm.trim() !== "" && key !== "" && (!plainHttp || allowHttp);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async () => {
    if (!ready || busy) return;
    setBusy(true);
    setError(null);
    const reply = await store.joinTailnetVM({
      vm: vm.trim(),
      key,
      oauth,
      ...options,
      allowHttp: plainHttp && allowHttp,
      switch: switchTailnet,
    });
    setBusy(false);
    if (reply.ok) {
      setKey("");
      onJoined(reply);
    } else {
      const detail =
        reply.errorCode === "missing_vm"
          ? t("settingsPage.tailnet.missingMachine")
          : reply.errorCode === "missing_key"
            ? t("settingsPage.tailnet.missingCredential")
            : (reply.error ?? t("settingsPage.tailnet.unknownError"));
      setError(detail);
    }
  };
  return (
    <Dialog
      open
      onOpenChange={(next) => !next && onClose()}
      label={t("settingsPage.tailnet.join")}
      className="tailnet-join-sheet"
    >
      <form
        className="tailnet-join-content"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <DialogTitle>{t("settingsPage.tailnet.join")}</DialogTitle>
        <DialogDescription>{t("settingsPage.tailnet.cloudHelp")}</DialogDescription>
        <label className="tailnet-join-field">
          {t("settingsPage.tailnet.machine")}
          <input
            list="tailnet-machines"
            data-tailnet-join-vm=""
            value={vm}
            onChange={(event) => setVM(event.target.value)}
            autoComplete="off"
          />
          <datalist id="tailnet-machines">
            {machines.map((machine) => (
              <option key={machine.id} value={machine.id}>
                {machine.title}
              </option>
            ))}
          </datalist>
        </label>
        <label className="tailnet-join-field">
          {t("settingsPage.tailnet.credential")}
          <input
            type="password"
            data-tailnet-join-key=""
            value={key}
            onChange={(event) => setKey(event.target.value)}
            autoComplete="off"
            spellCheck={false}
          />
        </label>
        <p>{t("settingsPage.tailnet.keyHelp")}</p>
        {reusable && (
          <p className="tailnet-join-warning" role="alert" data-tailnet-key-reusable="">
            {t("settingsPage.tailnet.reusableWarning")}
          </p>
        )}
        {plainHttp && (
          <label className="tailnet-join-check" data-tailnet-allow-http="">
            <input type="checkbox" checked={allowHttp} onChange={(event) => setAllowHttp(event.target.checked)} />
            <span>{t("settingsPage.tailnet.allowHttp", loginServer)}</span>
          </label>
        )}
        <label className="tailnet-join-check">
          <input type="checkbox" checked={oauth} onChange={(event) => setOAuth(event.target.checked)} />
          <span>{t("settingsPage.tailnet.oauthMode")}</span>
        </label>
        <label className="tailnet-join-check">
          <input type="checkbox" checked={switchTailnet} onChange={(event) => setSwitchTailnet(event.target.checked)} />
          <span>{t("settingsPage.tailnet.switch")}</span>
        </label>
        {error && (
          <p className="tailnet-join-error" role="alert">
            {t("settingsPage.tailnet.joinError", error)}
          </p>
        )}
        {error?.includes("another tailnet") && <p>{t("settingsPage.tailnet.switchHelp")}</p>}
        <div className="accounts-buttons">
          <Button type="button" className="button" onClick={onClose}>
            {t("settingsPage.cancel")}
          </Button>
          <Button type="submit" className="button" data-tailnet-join-submit="" disabled={busy || !ready}>
            {busy ? t("settingsPage.tailnet.joining") : t("settingsPage.tailnet.join")}
          </Button>
        </div>
      </form>
    </Dialog>
  );
}
