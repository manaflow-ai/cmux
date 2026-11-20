// Invite to cmux-next and Invite to <team>: one email address each.
//
// Invite to cmux-next lists the invites still waiting for someone to join; the host makes a team
// invite for a verified team domain, else a DM invite. Invite to <team> is the confirmation step
// of every team invite (the Home menus, the palette, New Message's To: row, and a CLI or agent
// run, which waits for the person here): it reads what a join costs the team while it shows and
// keeps Send off until that line is on screen. The line takes the place of "Checking the team's
// plan…", so nothing moves when it arrives.
import { useEffect, useState } from "react";
import type { Strings } from "../../shared/i18n";
import { parseAddress } from "./address";
import type { ComposeActions } from "./actions";
import { seatAllowsSending, seatImpactLine, type SeatImpact } from "./model";
import { SheetFrame, useSheetRun } from "./SheetFrame";

/** The typed address when it is an email, else the outcome that says it is not. */
function emailOf(text: string) {
  const parsed = parseAddress(text);
  return parsed?.kind === "email" ? parsed : null;
}

export interface InviteSheetProps {
  strings: Strings;
  actions: Pick<ComposeActions, "invite">;
  /** The addresses of invites nobody accepted yet. */
  pending: readonly string[];
  prefill?: string;
  onFinish(conversation: string | null): void;
}

export function InviteSheet({ strings, actions, pending, prefill = "", onFinish }: InviteSheetProps) {
  const { t, format } = strings;
  const sheet = useSheetRun(strings, onFinish);
  const [email, setEmail] = useState(prefill);
  const submit = () => {
    const address = emailOf(email);
    if (!address) return sheet.setStatus(format("home.outcome.invalidAddress", email));
    sheet.run(() => actions.invite(address));
  };
  return (
    <SheetFrame
      strings={strings}
      id="cmux.home.invite"
      title={t("home.invite.title")}
      primary={t("home.invite.send")}
      canSubmit={email.trim() !== ""}
      running={sheet.running}
      status={sheet.status}
      onSubmit={submit}
      onCancel={() => sheet.finish(null)}
    >
      <p className="hm-sheet-body">{t("home.invite.body")}</p>
      <input
        className="hc-link-field"
        type="email"
        value={email}
        placeholder={t("home.invite.email")}
        aria-label={t("home.invite.email")}
        data-testid="cmux.home.invite.email"
        onChange={(event) => setEmail(event.target.value)}
      />
      <h3 className="hm-sheet-header">{t("home.invite.pending")}</h3>
      <p className="hm-sheet-caption hm-sheet-pending" data-testid="cmux.home.invite.pending">
        {pending.length === 0 ? t("home.invite.nonePending") : pending.join("\n")}
      </p>
    </SheetFrame>
  );
}

export interface TeamInviteSheetProps {
  strings: Strings;
  actions: Pick<ComposeActions, "seatImpact" | "inviteToTeam">;
  /** The active team's name. */
  team: string;
  prefill?: string;
  /** Not the person's own gesture: a line asks them to check the address. */
  requestedByAgent?: boolean;
  onFinish(conversation: string | null): void;
}

export function TeamInviteSheet({
  strings,
  actions,
  team,
  prefill = "",
  requestedByAgent = false,
  onFinish,
}: TeamInviteSheetProps) {
  const { t, format } = strings;
  const sheet = useSheetRun(strings, onFinish);
  const [email, setEmail] = useState(prefill);
  const [impact, setImpact] = useState<SeatImpact | null>(null);
  // One read of the team's plan, when the sheet shows; a closed sheet drops its answer.
  useEffect(() => {
    let live = true;
    void actions.seatImpact().then((read) => {
      if (live) setImpact(read);
    });
    return () => {
      live = false;
    };
  }, [actions]);
  const submit = () => {
    const address = emailOf(email);
    if (!address) return sheet.setStatus(format("home.outcome.invalidAddress", email));
    sheet.run(() => actions.inviteToTeam(address));
  };
  return (
    <SheetFrame
      strings={strings}
      id="cmux.home.teamInvite"
      title={format("home.teamInvite.title", team)}
      primary={t("home.invite.send")}
      canSubmit={impact !== null && seatAllowsSending(impact) && email.trim() !== ""}
      running={sheet.running}
      status={sheet.status}
      onSubmit={submit}
      onCancel={() => sheet.finish(null)}
    >
      <p className="hm-sheet-body">{format("home.teamInvite.body", team)}</p>
      {requestedByAgent && (
        <p className="hm-sheet-note" data-testid="cmux.home.teamInvite.requested">
          {t("home.teamInvite.requested")}
        </p>
      )}
      <input
        className="hc-link-field"
        type="email"
        value={email}
        placeholder={t("home.invite.email")}
        aria-label={t("home.invite.email")}
        data-testid="cmux.home.teamInvite.email"
        onChange={(event) => setEmail(event.target.value)}
      />
      <p className="hm-sheet-caption" aria-busy={impact === null || undefined} data-testid="cmux.home.teamInvite.seats">
        {impact ? seatImpactLine(impact, strings) : t("home.teamInvite.checking")}
      </p>
    </SheetFrame>
  );
}
