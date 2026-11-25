// l10n-allow-file: gallery stand-in (sample machines and a scripted acpmux), not shipped UI.
//
// Door A end to end for the gallery and its recorded click-through (MachineJoinFlow.gallery.tsx):
// the real composer strip and the real join line over the page's real store (machineJoin.ts), with
// a scripted acpmux in place of the daemon. It answers `_acpmux/machine_candidates` with three of the
// person's tailnet nodes and two other hosts, and plays a join's steps: the person's own node joins
// (reach, token, install, connect), any other host asks first, and a confirmed `build-box` fails as
// a refused ssh key. The app never loads this file.
import { useEffect, useState } from "react";
import { ComposerContext } from "./ComposerContext";
import { MachineJoinLine } from "./MachineJoinLine";
import {
  noteJoinProgress,
  refreshJoinCandidates,
  setMachineJoinPort,
  setMachineJoinStateForTest,
  useMachineJoinState,
  type JoinStep,
} from "./machineJoin";

const CANDIDATES = [
  { name: "gcp-3", address: "gcp-3", os: "linux", found: "tailnet", mine: true },
  { name: "gcp-4", address: "gcp-4", os: "linux", found: "tailnet", mine: true },
  { name: "pi-kitchen", address: "pi-kitchen", os: "linux", found: "tailnet", mine: true },
  { name: "build-box", address: "build-box", found: "ssh-config", mine: false },
  { name: "shared-gpu", address: "shared-gpu", os: "linux", found: "tailnet", mine: false },
];
/// Each step's length in the scripted join (ms); a real one takes 12 to 16 s on a fresh VM.
const STEPS: [JoinStep, number][] = [
  ["reach", 900],
  ["token", 700],
  ["install", 3200],
  ["connect", 1200],
];

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function scriptedJoin(params: Record<string, unknown>): Promise<unknown> {
  const host = String(params.host ?? "");
  const joinId = String(params.joinId ?? "");
  const mine = CANDIDATES.some((candidate) => candidate.address === host && candidate.mine);
  if (!mine && params.confirmed !== true) {
    await wait(300);
    return { ok: false, failure: { kind: "needs_confirmation" }, confirm: { host, login: `you@${host}` } };
  }
  let seconds = 0;
  for (const [step, ms] of STEPS) {
    noteJoinProgress({ joinId, step, state: "running", seconds });
    if (!mine && step === "token") {
      await wait(ms);
      return {
        ok: false,
        seconds,
        failure: { kind: "needs_key", message: "Permission denied (publickey)", next: `ssh-copy-id ${host}` },
      };
    }
    await wait(ms);
    seconds += Math.round(ms / 1000);
  }
  return { ok: true, seconds, machine: { name: host.split(".")[0] } };
}

export function MachineJoinFlow() {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    setMachineJoinStateForTest(undefined);
    setMachineJoinPort({
      candidates: () => Promise.resolve({ candidates: CANDIDATES }),
      join: scriptedJoin,
    });
    void refreshJoinCandidates().then(() => setReady(true));
    return () => {
      setMachineJoinPort(undefined);
      setMachineJoinStateForTest(undefined);
    };
  }, []);
  if (!ready) return null;
  return (
    <div className="acpmux-join-flow" data-testid="machine-join-flow">
      <ComposerContext
        sessions={[]}
        projectChoices={[{ cwd: "/Users/you/src/cmux", label: "cmux" }]}
        localName="studio-mac"
        onProject={() => undefined}
        onBrowseProject={() => undefined}
        onConnect={() => undefined}
        environments
        cloudSignedIn
        runMode={{ mode: "persistent", onMode: () => undefined }}
      />
      <FlowLine />
    </div>
  );
}

/// The composer's own line reads the same store (Composer.tsx); here it stands alone under the strip.
function FlowLine() {
  const { join } = useMachineJoinState();
  return <MachineJoinLine join={join} onSignIn={() => undefined} onAddMachine={() => undefined} />;
}
