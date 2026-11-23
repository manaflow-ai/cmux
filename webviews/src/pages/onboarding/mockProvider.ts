// l10n-allow-file: public-safe gallery and browser development fixtures.
// `?mock`: the page on fixture states, answering gestures the way the host would, closely enough to
// click through each step in a plain browser.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { agentsState, computerUseState, importState, makeItYoursState } from "./fixtures";
import { OPS, type ImportDataKind, type MakeItYoursMaterial, type OnboardingState, type WorkStyle } from "./ops";
import type { AccountRowWire, AccountRunParams } from "../shared/signIn/accountSignIn";
import { MockAccountSignIn } from "../shared/signIn/mockSignIn";

export class MockOnboardingProvider implements PageClient {
  private state: OnboardingState;
  private readonly listeners = new Set<(state: OnboardingState) => void>();

  /** The in-place sign-in (`cmux.onboarding.accounts.run`), the same mock Settings runs; tests and
   * the gallery set its `hold` and `refusal`. */
  readonly signIn = new MockAccountSignIn({
    rows: () => this.state.signInAccounts ?? [],
    set: (next) => this.change(withAccounts(this.state, next)),
  });

  /** `initial`: the gallery's and tests' state instead of the step's fixture. */
  constructor(step: string = "agents", initial?: OnboardingState) {
    this.state =
      initial ??
      (step === "importData"
        ? importState("idle")
        : step === "computerUse"
          ? computerUseState("fresh")
          : step === "makeItYours"
            ? makeItYoursState("fresh")
            : agentsState("mixed"));
  }

  private change(next: OnboardingState): void {
    this.state = next;
    for (const listener of this.listeners) listener(next);
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    const input = (params ?? {}) as {
      id?: string | null;
      kind?: ImportDataKind;
      target?: string | null;
      pane?: string;
      value?: string | number;
    };
    const state = this.state;
    switch (op) {
      case OPS.state:
        return state as R;
      case OPS.focused:
        return {} as R;
      case OPS.next:
        if (state.step === "importData" && state.importer?.phase === "idle") this.change(importState("ready"));
        else if (state.step === "importData" && state.importer?.phase === "ready") this.change(importState("finished"));
        else if (state.step === "importData" && state.importer?.phase === "explainingAccess")
          this.change(importState("ready"));
        return {} as R;
      case OPS.back:
        if (state.step === "importData") this.change(importState("ready"));
        return {} as R;
      case OPS.accountsRun:
        return (await this.signIn.run(params as AccountRunParams)) as R;
      case OPS.signIn:
        if (state.agents) this.change({ ...state, agents: { ...state.agents, signingIn: input.id ?? null } });
        return {} as R;
      case OPS.askAccess:
        this.change(importState("access"));
        return {} as R;
      case OPS.toggleProfile:
      case OPS.toggleKind:
      case OPS.toggleKeepInSync:
      case OPS.setTarget: {
        const importer = state.importer;
        if (!importer) return {} as R;
        const rows = importer.rows.map((row) =>
          row.kind === "profile" && row.id === input.id
            ? op === OPS.setTarget
              ? { ...row, target: input.target ?? null }
              : { ...row, checked: !row.checked }
            : row,
        );
        const kind = input.kind;
        const kinds =
          op === OPS.toggleKind && kind
            ? importer.kinds.includes(kind)
              ? importer.kinds.filter((other) => other !== kind)
              : importer.kindChoices.filter((other) => other === kind || importer.kinds.includes(other))
            : importer.kinds;
        const keepsHistoryInSync =
          op === OPS.toggleKeepInSync ? !importer.keepsHistoryInSync : importer.keepsHistoryInSync;
        this.change({ ...state, importer: { ...importer, rows, kinds, keepsHistoryInSync } });
        return {} as R;
      }
      case OPS.allow: {
        const computerUse = state.computerUse;
        if (!computerUse) return {} as R;
        const rows = computerUse.rows.map((row) =>
          row.pane === input.pane ? { ...row, control: "done" as const } : row,
        );
        const next = rows.find((row) => row.control !== "done");
        const allGranted = next === undefined;
        this.change({
          ...state,
          footer: { ...state.footer, primaryEnabled: allGranted },
          computerUse: {
            ...computerUse,
            allGranted,
            comebacks: computerUse.comebacks + 1,
            rows: rows.map((row) => (row === next ? { ...row, control: "allowPrimary" as const } : row)),
          },
        });
        return {} as R;
      }
      case OPS.skip:
        return {} as R;
      case OPS.workStyle:
      case OPS.density:
      case OPS.background:
      case OPS.opacity:
      case OPS.material: {
        const choices = state.makeItYours;
        if (!choices) return {} as R;
        const next =
          op === OPS.workStyle
            ? { ...choices, workStyle: input.value as WorkStyle }
            : op === OPS.density
              ? { ...choices, density: String(input.value) }
              : op === OPS.opacity
                ? { ...choices, opacity: Number(input.value), opacitySet: true }
                : op === OPS.material
                  ? { ...choices, material: input.value as MakeItYoursMaterial }
                  : { ...choices, background: input.id ?? null };
        this.change({ ...state, makeItYours: next });
        return {} as R;
      }
      case OPS.install:
      case OPS.openFullDiskAccess:
      case OPS.fromFiles:
      case OPS.passwordsCSV:
      case OPS.skipPasswords:
      case OPS.restart:
        return {} as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream !== OPS.changed) return () => {};
    let seq = 0;
    const listener = (state: OnboardingState) => onEvent(state as E, ++seq);
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

/** What the daemon decides once the accounts change: a provider with a signed-in account is ready
 * (its default account's name), one without needs a sign-in; one not installed stays so. */
function withAccounts(state: OnboardingState, accounts: AccountRowWire[]): OnboardingState {
  const readiness = state.signInReadiness;
  if (!readiness) return { ...state, signInAccounts: accounts };
  const providers = readiness.providers.map((provider) => {
    if (provider.state === "notInstalled") return provider;
    const signedIn = accounts.filter((row) => row.family === provider.family && row.signedIn);
    const shown = signedIn.find((row) => row.default) ?? signedIn[0];
    return shown
      ? { family: provider.family, state: "ready" as const, account: shown.id, label: shown.name }
      : { family: provider.family, state: "signInRequired" as const };
  });
  return { ...state, signInAccounts: accounts, signInReadiness: { providers } };
}
