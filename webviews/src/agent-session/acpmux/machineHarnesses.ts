// Whether the agent a new chat will start with is set up on the machine it will start on (Austin,
// 2026-11-12: "ideally we should check if the model that is selected is supported on that machine
// as well but this should just work"). acpmux forwards `_acpmux/harnesses` to the peer that
// `_meta.acpmux.peer` names and answers with that machine's own reply plus `peer` (cmux-tui
// crates/acpmux/src/server/requests.rs, 5 s limit): `{harnesses: {<id>: {kind?, pickerHidden?,
// unavailable?, ...}}, defaultHarness, ..., peer}`. The reply lists agents, not models: which
// models each runs is `_acpmux/models`, so the check is per agent only.
import { useEffect, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { isModelRouterKind } from "./routerKinds";

/// The agents a machine can start a chat with, and the one it starts by default.
export type MachineHarnesses = {
  readonly ids: ReadonlySet<string>;
  readonly defaultHarness?: string;
};

/// A peer's `_acpmux/harnesses` reply as the agents a chat there can start on: neither a terminal
/// nor a model router, nor hidden from the picker, nor refused by its launcher check (`unavailable`).
/// Undefined when the reply is not a harness list, which the composer treats as no answer.
export function readMachineHarnesses(reply: unknown): MachineHarnesses | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const { harnesses, defaultHarness } = reply as { harnesses?: unknown; defaultHarness?: unknown };
  if (!harnesses || typeof harnesses !== "object") return undefined;
  const rows: [string, unknown][] = Array.isArray(harnesses)
    ? harnesses.map((row: unknown) => [String((row as { id?: unknown; name?: unknown })?.id ?? ""), row])
    : Object.entries(harnesses);
  const ids = new Set<string>();
  for (const [id, row] of rows) {
    if (!id || !row || typeof row !== "object") continue;
    const harness = row as { kind?: unknown; pickerHidden?: unknown; unavailable?: unknown };
    if (harness.kind === "terminal" || isModelRouterKind(harness.kind) || harness.pickerHidden === true) continue;
    if (typeof harness.unavailable === "string" && harness.unavailable) continue;
    ids.add(id);
  }
  return {
    ids,
    ...(typeof defaultHarness === "string" && ids.has(defaultHarness) ? { defaultHarness } : {}),
  };
}

/// What the composer does about the picked agent before Send: nothing (`ok`: it is set up there, or
/// the machine did not answer, which never holds a send), switch to the one agent the machine
/// starts by default (`switch`), or hold Send with a notice until the person picks one the machine
/// has (`missing`).
export type MachineHarnessVerdict = { kind: "ok" } | { kind: "switch"; to: string } | { kind: "missing" };

export function machineHarnessVerdict(
  selected: string | undefined,
  machine: MachineHarnesses | undefined,
): MachineHarnessVerdict {
  if (!machine || !selected || machine.ids.has(selected)) return { kind: "ok" };
  // The one sensible default: the agent the machine starts by default, else its only agent.
  const only = machine.ids.size === 1 ? [...machine.ids][0] : undefined;
  const to = machine.defaultHarness ?? only;
  return to ? { kind: "switch", to } : { kind: "missing" };
}

/// The catalog the composer's model picker reads while a machine is the pick: an agent that machine
/// lacks stays listed, its models disabled with `note` ("Not set up on studio"), so the list never
/// offers what the chat cannot start on there. The same array when nothing is missing.
export function withMachineHarnesses(
  catalog: AcpmuxSnapshot["catalog"],
  machine: MachineHarnesses | undefined,
  note: string,
): AcpmuxSnapshot["catalog"] {
  if (!machine) return catalog;
  const missing = (entry: AcpmuxSnapshot["catalog"][number]) =>
    !entry.folder && entry.pickable !== false && !machine.ids.has(entry.id);
  if (!catalog.some(missing)) return catalog;
  return catalog.map((entry) =>
    missing(entry)
      ? {
          ...entry,
          unavailable: note,
          // Listed, as a failed probe is, rather than dropped: the picker shows why it is greyed.
          probeFailed: true,
          models: entry.models.map((model) => ({ ...model, unavailable: note })),
        }
      : entry,
  );
}

/// What the composer shows for the picked agent on the machine a new chat will start on.
/// `blocked`: Send stays off (the agent is not set up there, or the switch to one that is has not
/// landed yet). `notice`: say so above the composer, which only a `missing` verdict does, or a
/// `switch` already asked for that did not take (the person picked the missing agent again).
export type MachineHarnessCheck = { blocked: boolean; notice: boolean };

/// Runs `switchTo` once for each machine and agent a `switch` verdict names, the pick the person
/// would make in the model picker, so a chat on that machine never starts on an agent it lacks.
/// An effect, not an event handler: the verdict changes when the machine's answer arrives, which no
/// gesture of the person's marks.
export function useMachineHarnessCheck({
  peer,
  selected,
  verdict,
  switching,
  switchTo,
}: {
  peer: string | undefined;
  selected: string | undefined;
  verdict: MachineHarnessVerdict;
  /// A harness switch is under way (its intent is the selection meanwhile).
  switching: boolean;
  switchTo(harness: string): void;
}): MachineHarnessCheck {
  // The last switch asked for; state, so the notice reads it in the render after the ask.
  const [asked, setAsked] = useState<string | undefined>(undefined);
  const askedRef = useRef<string | undefined>(undefined);
  const latest = useRef(switchTo);
  latest.current = switchTo;
  const to = verdict.kind === "switch" ? verdict.to : undefined;
  const key = to !== undefined && peer ? `${peer}\u0000${selected ?? ""}\u0000${to}` : undefined;
  useEffect(() => {
    if (key === undefined || to === undefined || askedRef.current === key) return;
    askedRef.current = key;
    setAsked(key);
    latest.current(to);
  }, [key, to]);
  if (verdict.kind === "ok") return { blocked: false, notice: false };
  if (verdict.kind === "missing") return { blocked: true, notice: true };
  return { blocked: true, notice: asked === key && !switching };
}
