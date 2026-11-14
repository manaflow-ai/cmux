// l10n-allow-file: the browser dev loop's stand-in host and the gallery's fixtures, not shipped UI.
// An in-memory Add Machine host (`/server-cards/?mock#/add-machine`): two tailnet machines, Add
// runs the nine steps a line every 400 ms and ends ready; a host named `fail…` fails at the daemon.
import { KNOWN_STEPS } from "./checklist";
import { AddMachineOps, type AddMachineStatus, type HostCandidate, type RunEvent } from "./types";

export const mockCandidates: HostCandidate[] = [
  {
    id: "dev-box.tail1.ts.net",
    name: "dev-box",
    os: "linux",
    online: true,
    alreadyPeer: false,
    sshOK: true,
    inApp: false,
    destination: "dev-box.tail1.ts.net",
    pickable: true,
  },
  {
    id: "studio.tail1.ts.net",
    name: "studio",
    os: "macOS",
    online: true,
    alreadyPeer: true,
    peer: "studio",
    inApp: false,
    destination: "studio",
    pickable: true,
  },
  {
    id: "build-01.tail1.ts.net",
    name: "build-01",
    os: "linux",
    online: true,
    alreadyPeer: false,
    sshOK: false,
    inApp: false,
    destination: "build-01.tail1.ts.net",
    pickable: false,
  },
  {
    id: "old-mini.tail1.ts.net",
    name: "old-mini",
    os: "macOS",
    online: false,
    alreadyPeer: false,
    inApp: false,
    destination: "old-mini.tail1.ts.net",
    pickable: false,
  },
];

export const stepLine = (step: string, state: string, detail = "", fix?: string) =>
  JSON.stringify({ step, state, detail, ...(fix ? { fix } : {}) });

export const reportLine = (name: string, host: string, ok: boolean, steps: string[]) =>
  `{"report":{"name":"${name}","host":"${host}","ok":${ok},"steps":[${steps.join(",")}]}}`;

const okSteps = KNOWN_STEPS.map((step) => stepLine(step, "ok"));

/** Statuses the gallery and the tests show. */
export const fixtures = {
  pick: (destination = ""): AddMachineStatus => ({ request: { seq: 1, mode: { kind: "add" }, destination } }),
  running: (): AddMachineStatus => ({
    request: { seq: 1, mode: { kind: "add" } },
    run: {
      id: 1,
      host: "dev-box",
      name: "dev-box",
      outcome: "running",
      events: [
        { kind: "start" },
        { kind: "line", line: stepLine("reach", "ok", "ssh dev-box answered") },
        { kind: "line", line: stepLine("install", "fixed", "pushed cmux-tui 0.67.0") },
      ],
    },
  }),
  ready: (): AddMachineStatus => ({
    request: { seq: 1, mode: { kind: "add" } },
    run: {
      id: 1,
      host: "dev-box",
      name: "dev-box",
      outcome: "ready",
      machineID: "ssh-dev-box",
      events: [
        { kind: "start" },
        ...okSteps.map((line): RunEvent => ({ kind: "line", line })),
        { kind: "line", line: reportLine("dev-box", "dev-box", true, okSteps) },
      ],
    },
  }),
  failed: (): AddMachineStatus => {
    const fail = stepLine(
      "reach",
      "fail",
      "ssh: connect to host dev-box port 22: Connection refused",
      "Turn on Remote Login on dev-box (System Settings > General > Sharing).",
    );
    return {
      request: { seq: 1, mode: { kind: "add" } },
      run: {
        id: 1,
        host: "dev-box",
        name: "dev-box",
        outcome: "failed",
        events: [
          { kind: "start" },
          { kind: "line", line: fail },
          { kind: "line", line: reportLine("dev-box", "dev-box", false, [fail]) },
        ],
      },
    };
  },
  check: (): AddMachineStatus => {
    const fail = stepLine(
      "daemon",
      "fail",
      "daemon status did not answer in 5 s",
      "Run Fix to start the agent daemon again.",
    );
    const steps = [stepLine("reach", "ok"), stepLine("install", "ok"), fail];
    return {
      request: { seq: 1, mode: { kind: "check", host: "leo@dev-box", machineID: "ssh-1" } },
      run: {
        id: 1,
        host: "leo@dev-box",
        name: "dev-box",
        outcome: "failed",
        events: [
          { kind: "start" },
          ...steps.map((line): RunEvent => ({ kind: "line", line })),
          { kind: "line", line: reportLine("dev-box", "dev-box", false, steps) },
        ],
      },
    };
  },
};

/** The dev loop's host: answers `cmux.addMachine.*` and plays a run when Add is pressed. */
export class MockAddMachineHost {
  status: AddMachineStatus;
  private timers: ReturnType<typeof setTimeout>[] = [];

  constructor(
    private readonly changed: () => void,
    initial: AddMachineStatus = fixtures.pick(),
    private readonly candidates: HostCandidate[] | null = mockCandidates,
  ) {
    this.status = initial;
  }

  call(op: string, params: unknown): unknown {
    const args = (params ?? {}) as Record<string, unknown>;
    switch (op) {
      case AddMachineOps.status:
        return this.status;
      case AddMachineOps.parse: {
        const text = String(args.text ?? "").trim();
        if (!text || /\s|:/.test(text)) return null;
        const host = text.split("@").at(-1)!;
        return { host: text, shortName: host.split(".")[0] };
      }
      case AddMachineOps.candidates:
        return this.candidates;
      case AddMachineOps.add:
        this.play(String(args.destination ?? ""), String(args.name ?? ""));
        return null;
      case AddMachineOps.cancel:
        this.stop();
        this.status = { request: this.status.request };
        this.changed();
        return null;
      default:
        return null;
    }
  }

  private play(host: string, name: string) {
    this.stop();
    const fails = host.startsWith("fail");
    const events: RunEvent[] = [{ kind: "start" }];
    this.status = { request: this.status.request, run: { id: Date.now(), host, name, outcome: "running", events } };
    this.changed();
    const steps = fails ? KNOWN_STEPS.slice(0, 3) : KNOWN_STEPS;
    const lines = steps.map((step, index) =>
      fails && index === 2
        ? stepLine(step, "fail", "daemon status timed out", "Log in on the host once.")
        : stepLine(step, "ok"),
    );
    lines.forEach((line, index) => {
      this.timers.push(
        setTimeout(
          () => {
            const run = this.status.run!;
            const done = index === lines.length - 1;
            this.status = {
              request: this.status.request,
              run: {
                ...run,
                events: [
                  ...run.events,
                  { kind: "line", line },
                  ...(done ? [{ kind: "line" as const, line: reportLine(name, host, !fails, lines) }] : []),
                ],
                outcome: done ? (fails ? "failed" : "ready") : "running",
                ...(done && !fails ? { machineID: `ssh-${host}` } : {}),
              },
            };
            this.changed();
          },
          400 * (index + 1),
        ),
      );
    });
  }

  private stop() {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers = [];
  }
}
