// l10n-allow-file: the browser dev loop's stand-in owner, not shipped UI.
// An in-memory server for the browser dev loop (`/server-cards/?mock#/server-panel`) and the page
// tests: one canned scenario, each intent applied and echoed on the next turn as the app's owner
// would (the switch, a new pairing code, Fix resolves its alert, Revoke drops the device), and the
// Add Server flow (offerCode finds build-01; the native Approve, `personPressed`, adds it a moment
// later; the dev loop stops at the review, as Approve is the app panel's own button).
import { candidate, offer, offerCode, status, type ServerScenario } from "./fixtures";
import { PairingCode } from "./model";
import { ServerOps, type ServerApprover, type ServerIntent, type ServerStatus } from "./types";

export class MockServerOwner {
  private state: ServerStatus;
  private readonly listeners = new Set<() => void>();
  readonly received: { op: string; params: unknown }[] = [];

  constructor(
    name: ServerScenario = "healthyMac",
    private readonly approveDelay = 600,
  ) {
    this.state = status(name);
  }

  handles(op: string): boolean {
    return op.startsWith("cmux.server.");
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  get current(): ServerStatus {
    return this.state;
  }

  async call(op: string, params: unknown): Promise<unknown> {
    this.received.push({ op, params });
    const p = (params ?? {}) as Record<string, unknown>;
    switch (op) {
      case ServerOps.status:
        return structuredClone(this.state);
      case ServerOps.send:
        this.apply(p as unknown as ServerIntent);
        return null;
      case ServerOps.setCode:
        this.setCode(String(p.code ?? ""));
        return null;
      case ServerOps.setName:
        this.approver({ draft: { ...this.state.approver.draft, name: String(p.name ?? "") } });
        return null;
      case ServerOps.setTeam:
        this.approver({ draft: { ...this.state.approver.draft, team: String(p.team ?? "") } });
        return null;
      case ServerOps.setRunChief:
        this.approver({ draft: { ...this.state.approver.draft, runChief: p.on === true } });
        return null;
      case ServerOps.cancel:
        this.approver({
          step: "enterCode",
          candidate: undefined,
          reject: undefined,
          added: undefined,
          canApprove: false,
          draft: { code: "", name: "", runChief: false },
        });
        return null;
      default:
        throw new Error(op);
    }
  }

  private apply(intent: ServerIntent) {
    const snapshot = this.state.snapshot ? structuredClone(this.state.snapshot) : undefined;
    if (!snapshot) return;
    switch (intent.kind) {
      case "setEnabled":
        snapshot.enabled = intent.on;
        for (const role of snapshot.roles) if (role.role !== "automations") role.state = intent.on ? "on" : "off";
        break;
      case "showPairingCode":
        if (snapshot.pairing.state !== "paired") snapshot.pairing = { state: "unpaired", offer: offer(Date.now()) };
        break;
      case "fixCheck": {
        const alert = snapshot.alerts.find((entry) => entry.check === intent.check && entry.resolvedAt === undefined);
        if (alert) alert.resolvedAt = Date.now();
        break;
      }
      case "revokeDevice":
        snapshot.devices = snapshot.devices.filter((device) => device.id !== intent.device);
        break;
    }
    queueMicrotask(() => this.update({ ...this.state, snapshot, lastReject: undefined }));
  }

  private setCode(text: string) {
    const code = PairingCode.editing(text);
    const complete = PairingCode.isComplete(code);
    this.approver({
      step: complete ? "lookingUp" : "enterCode",
      candidate: undefined,
      reject: undefined,
      canApprove: false,
      draft: { ...this.state.approver.draft, code },
    });
    if (!complete) return;
    queueMicrotask(() => {
      if (this.state.approver.draft.code !== code) return;
      if (PairingCode.normalize(code) !== offerCode) {
        this.approver({ step: "codeRefused", reject: "No server is waiting with that code." });
        return;
      }
      const draft = this.state.approver.draft;
      this.approver({
        step: "review",
        candidate,
        canApprove: true,
        draft: {
          ...draft,
          team: draft.team ?? candidate.teams[0]!.id,
          name: draft.name || candidate.name,
          runChief: candidate.isChiefBrain,
        },
      });
    });
  }

  /** The person clicked the panel's native Approve or Try Again (ServerPageProvider.personPressed):
   * no page op approves, so the tests press it here. */
  personPressed() {
    const name = this.state.approver.draft.name.trim() || this.state.approver.candidate?.name || "";
    const step = this.state.approver.step;
    if ((step !== "review" && step !== "approveFailed") || !this.state.approver.canApprove) return;
    this.approver({ step: "approving", canApprove: false, draft: { ...this.state.approver.draft, name } });
    setTimeout(
      () =>
        this.approver({
          step: "added",
          added: name,
          candidate: undefined,
          draft: { code: "", name: "", runChief: false },
        }),
      this.approveDelay,
    );
  }

  /** The server refused the approve of the found server (Try Again shows). */
  refuse(reject: string) {
    if (!this.state.approver.candidate) return;
    this.approver({ step: "approveFailed", reject, canApprove: true });
  }

  /** The card opened again (a new session). */
  open() {
    this.approver({ session: this.state.approver.session + 1, step: "enterCode", added: undefined, reject: undefined });
  }

  private approver(next: Partial<ServerApprover>) {
    this.update({ ...this.state, approver: { ...this.state.approver, ...next } });
  }

  private update(next: ServerStatus) {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
