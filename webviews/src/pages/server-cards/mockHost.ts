// l10n-allow-file: the browser dev loop's stand-in host, not shipped UI.
// An in-memory server card host for the browser dev loop (`/server-cards/?mock#/pair-invite`): the
// invite mints a moment after the card opens and a machine arrives a few seconds later. Confirm is
// the app panel's native button, so the dev loop stops at the review. The server surfaces' ops
// (`#/server-panel`, `#/add-server`) go to MockServerOwner; the join consent ask (`#/join-consent`)
// answers from its own stand-in.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { CardOps } from "./host";
import { MockJoinConsent } from "./join-consent/fixtures";
import { JoinConsentOps } from "./join-consent/types";
import { arrivedStatus, mintingStatus, showingStatus } from "./pairInvite/fixtures";
import { PairInviteOps, type PairInviteStatus } from "./pairInvite/types";
import { MockServerOwner } from "./server/mockOwner";
import { ServerOps } from "./server/types";

export class MockServerCardsHost implements PageClient {
  private status: PairInviteStatus = mintingStatus();
  private listeners = new Set<() => void>();
  private timers: ReturnType<typeof setTimeout>[] = [];
  private readonly joinConsent = new MockJoinConsent();
  readonly server = new MockServerOwner();

  constructor(initial?: PairInviteStatus) {
    if (initial) this.status = initial;
    else this.mint();
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    if (op.startsWith("cmux.joinConsent.")) return this.joinConsent.call(op) as R;
    if (this.server.handles(op)) return (await this.server.call(op, params)) as R;
    switch (op) {
      case PairInviteOps.status:
        return this.status as R;
      case PairInviteOps.newCode:
        this.mint();
        return null as R;
      case PairInviteOps.copy:
        return null as R;
      case PairInviteOps.setRunChief:
        this.update({
          ...this.status,
          approver: { ...this.status.approver, runChief: (params as { on?: boolean }).on === true },
        });
        return null as R;
      case PairInviteOps.setName:
        return null as R;
      case CardOps.resize:
      case CardOps.close:
        return null as R;
      default:
        throw pageError("cmux.op.unknown", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === CardOps.commands) return () => {};
    if (stream === JoinConsentOps.changes) {
      let seq = 0;
      return this.joinConsent.subscribe(() => onEvent({} as E, ++seq));
    }
    if (stream === ServerOps.changes) {
      let seq = 0;
      return this.server.onChange(() => onEvent({} as E, ++seq));
    }
    if (stream !== PairInviteOps.changes) throw pageError("cmux.op.unknown", stream);
    let seq = 0;
    const listener = () => onEvent({} as E, ++seq);
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  private mint() {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers = [];
    const session = this.status.session + 1;
    this.update({ ...mintingStatus(), session });
    this.later(400, () => this.update({ ...showingStatus(Date.now()), session }));
    this.later(6000, () =>
      this.update({ ...arrivedStatus(Date.now(), { step: "lookingUp", candidate: undefined }), session }),
    );
    this.later(7000, () => this.update({ ...arrivedStatus(Date.now()), session }));
  }

  private later(ms: number, run: () => void) {
    this.timers.push(setTimeout(run, ms));
  }

  private update(status: PairInviteStatus) {
    this.status = status;
    for (const listener of this.listeners) listener();
  }
}
