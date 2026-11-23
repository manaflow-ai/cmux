// l10n-allow-file: public-safe gallery and browser development fixtures.
// `?mock`: the page on fixture states, answering gestures the way the host would, closely enough to
// click through each step in a plain browser.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { agentToolsState, agentsState, computerUseState, importState, makeItYoursState } from "./fixtures";
import { OPS, type DensityChoice, type ImportDataKind, type OnboardingState, type WorkStyle } from "./ops";

export class MockOnboardingProvider implements PageClient {
  private state: OnboardingState;
  /** Make cmux Yours' choices when the window opened: Skip puts them back, as the host does (cmux#49701's
   * keepForSkip). */
  private readonly openingChoices: OnboardingState["makeItYours"];
  private readonly listeners = new Set<(state: OnboardingState) => void>();

  /** `initial`: the state to open on (a gallery variant's fixture); else `step`'s first fixture. */
  constructor(step: string = "agents", initial?: OnboardingState) {
    this.state =
      initial ??
      (step === "importData"
        ? importState("idle")
        : step === "computerUse"
          ? computerUseState("fresh")
          : step === "agentTools"
            ? agentToolsState("found")
            : step === "makeItYours"
              ? makeItYoursState("fresh")
              : agentsState("mixed"));
    this.openingChoices = this.state.makeItYours ?? null;
  }

  private change(next: OnboardingState): void {
    this.state = next;
    for (const listener of this.listeners) listener(next);
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    // The intro walk probe (scripts/intro-walk.mjs) counts the ops each click sends.
    const log = (globalThis as { cmuxOnboardingMockCalls?: { op: string; params: unknown }[] }).cmuxOnboardingMockCalls;
    log?.push({ op, params });
    const input = (params ?? {}) as {
      id?: string | null;
      kind?: ImportDataKind;
      target?: string | null;
      pane?: string;
      value?: string;
    };
    const state = this.state;
    switch (op) {
      case OPS.state:
        return state as R;
      case OPS.focused:
        return {} as R;
      case OPS.next:
        if (state.step === "agentTools" && !state.agentTools?.answered) this.change(agentToolsState("added"));
        if (state.step === "importData" && state.importer?.phase === "idle") this.change(importState("ready"));
        else if (state.step === "importData" && state.importer?.phase === "ready") this.change(importState("finished"));
        else if (state.step === "importData" && state.importer?.phase === "explainingAccess")
          this.change(importState("ready"));
        return {} as R;
      case OPS.back:
        if (state.step === "importData") this.change(importState("ready"));
        return {} as R;
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
        if (state.step === "makeItYours" && state.makeItYours && this.openingChoices)
          this.change({ ...state, makeItYours: { ...state.makeItYours, ...pickedChoices(this.openingChoices) } });
        if (state.step === "agentTools" && !state.agentTools?.answered) this.change(agentToolsState("declined"));
        return {} as R;
      case OPS.workStyle:
      case OPS.density:
      case OPS.background: {
        const choices = state.makeItYours;
        if (!choices) return {} as R;
        const next =
          op === OPS.workStyle
            ? { ...choices, workStyle: input.value as WorkStyle }
            : op === OPS.density
              ? { ...choices, density: input.value as DensityChoice }
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

/** The three picks of Make cmux Yours, without the backgrounds offered or their load state. */
function pickedChoices(choices: NonNullable<OnboardingState["makeItYours"]>) {
  return { workStyle: choices.workStyle, density: choices.density, background: choices.background };
}
