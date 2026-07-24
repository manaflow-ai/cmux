import { describe, expect, test } from "bun:test";

const terminalStreamPath =
  "../app/[locale]/share/[code]/" + "terminal-stream";
const loadedTerminalStreamModule = await import(terminalStreamPath).catch(
  () => null,
) as TerminalStreamModule | null;

const PROTOCOL_VERSION = 2;
const TERMINAL_VERSION = 1;

type TerminalError = {
  readonly code:
    | "protocol_version_mismatch"
    | "terminal_version_mismatch";
  readonly message: string;
};

type BaselineFrame = {
  readonly kind: "baseline";
  readonly protocolVersion: number;
  readonly terminalVersion: number;
  readonly streamEpoch: string;
  readonly sequenceEnd: number;
  readonly rows: number;
  readonly columns: number;
  readonly data: Uint8Array;
};

type OutputFrame = {
  readonly kind: "output";
  readonly streamEpoch: string;
  readonly sequenceStart: number;
  readonly sequenceEnd: number;
  readonly data: Uint8Array;
};

type InputFrame = {
  readonly kind: "input";
  readonly data: Uint8Array;
};

type TerminalFrame = BaselineFrame | OutputFrame;

type TerminalStreamCoordinatorLike = {
  readonly terminalError: TerminalError | null;
  consume(frame: TerminalFrame): Promise<boolean>;
  onData(data: string): boolean;
  onBinary(data: string): boolean;
};

type TerminalStreamModule = {
  readonly TerminalStreamCoordinator: new (options: {
    readonly protocolVersion: number;
    readonly terminalVersion: number;
    readonly resize: (columns: number, rows: number) => void;
    readonly write: (
      data: Uint8Array,
      onConsumed: () => void,
    ) => void;
    readonly onResyncRequested: (reason: string) => void;
    readonly sendTerminalInput: (frame: InputFrame) => boolean;
  }) => TerminalStreamCoordinatorLike;
};

type PendingWrite = {
  readonly data: Uint8Array;
  readonly complete: () => void;
};

function terminalStreamModule(): TerminalStreamModule {
  expect(loadedTerminalStreamModule).not.toBeNull();
  return loadedTerminalStreamModule as TerminalStreamModule;
}

function bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function baseline(
  overrides: Partial<BaselineFrame> = {},
): BaselineFrame {
  return {
    kind: "baseline",
    protocolVersion: PROTOCOL_VERSION,
    terminalVersion: TERMINAL_VERSION,
    streamEpoch: "epoch-a",
    sequenceEnd: 10,
    rows: 24,
    columns: 80,
    data: bytes("\u001b[2Jbaseline"),
    ...overrides,
  };
}

function output(
  overrides: Partial<OutputFrame> = {},
): OutputFrame {
  return {
    kind: "output",
    streamEpoch: "epoch-a",
    sequenceStart: 10,
    sequenceEnd: 13,
    data: bytes("abc"),
    ...overrides,
  };
}

function harness(): {
  readonly coordinator: TerminalStreamCoordinatorLike;
  readonly writes: PendingWrite[];
  readonly resizes: Array<[columns: number, rows: number]>;
  readonly resyncRequests: string[];
  readonly sentInput: InputFrame[];
} {
  const writes: PendingWrite[] = [];
  const resizes: Array<[columns: number, rows: number]> = [];
  const resyncRequests: string[] = [];
  const sentInput: InputFrame[] = [];
  const { TerminalStreamCoordinator } = terminalStreamModule();
  const coordinator = new TerminalStreamCoordinator({
    protocolVersion: PROTOCOL_VERSION,
    terminalVersion: TERMINAL_VERSION,
    resize: (columns, rows) => {
      resizes.push([columns, rows]);
    },
    write: (data, onConsumed) => {
      writes.push({
        data: data.slice(),
        complete: onConsumed,
      });
    },
    onResyncRequested: (reason) => {
      resyncRequests.push(reason);
    },
    sendTerminalInput: (frame) => {
      sentInput.push({
        kind: frame.kind,
        data: frame.data.slice(),
      });
      return true;
    },
  });
  return {
    coordinator,
    writes,
    resizes,
    resyncRequests,
    sentInput,
  };
}

async function settle(): Promise<void> {
  for (let turn = 0; turn < 4; turn += 1) {
    await Promise.resolve();
  }
}

async function consumeCompletedBaseline(
  fixture: ReturnType<typeof harness>,
  frame: BaselineFrame = baseline(),
): Promise<void> {
  const receipt = fixture.coordinator.consume(frame);
  await settle();
  expect(fixture.writes).toHaveLength(1);
  fixture.writes[0]?.complete();
  expect(await receipt).toBe(true);
}

describe("TerminalStreamCoordinator output ordering", () => {
  test("serializes baseline before raw output and exposes ACK readiness only after each async write", async () => {
    const fixture = harness();
    let baselineAckReady: boolean | undefined;
    let outputAckReady: boolean | undefined;

    const baselineReceipt = fixture.coordinator.consume(baseline()).then(
      (accepted) => {
        baselineAckReady = accepted;
        return accepted;
      },
    );
    const outputReceipt = fixture.coordinator.consume(output()).then(
      (accepted) => {
        outputAckReady = accepted;
        return accepted;
      },
    );
    await settle();

    expect(fixture.resizes).toEqual([[80, 24]]);
    expect(fixture.writes.map((write) => [...write.data])).toEqual([
      [...bytes("\u001b[2Jbaseline")],
    ]);
    expect(baselineAckReady).toBeUndefined();
    expect(outputAckReady).toBeUndefined();

    fixture.writes[0]?.complete();
    expect(await baselineReceipt).toBe(true);
    await settle();

    expect(fixture.writes.map((write) => [...write.data])).toEqual([
      [...bytes("\u001b[2Jbaseline")],
      [...bytes("abc")],
    ]);
    expect(outputAckReady).toBeUndefined();

    fixture.writes[1]?.complete();
    expect(await outputReceipt).toBe(true);
    expect(outputAckReady).toBe(true);
    expect(fixture.resyncRequests).toEqual([]);
  });

  test("rejects output before a baseline and requests resync without writing bytes", async () => {
    const fixture = harness();

    expect(await fixture.coordinator.consume(output())).toBe(false);
    expect(fixture.writes).toEqual([]);
    expect(fixture.resyncRequests).toEqual(["baseline_required"]);
  });

  for (const invalid of [
    {
      name: "sequence gap",
      frame: output({ sequenceStart: 12, sequenceEnd: 15 }),
      reason: "sequence_gap",
    },
    {
      name: "sequence overlap",
      frame: output({ sequenceStart: 9, sequenceEnd: 12 }),
      reason: "sequence_gap",
    },
    {
      name: "payload length mismatch",
      frame: output({ sequenceStart: 10, sequenceEnd: 14 }),
      reason: "sequence_gap",
    },
    {
      name: "stream epoch mismatch",
      frame: output({ streamEpoch: "epoch-b" }),
      reason: "stream_epoch_mismatch",
    },
  ]) {
    test(`requests resync for ${invalid.name} without writing corrupt output`, async () => {
      const fixture = harness();
      await consumeCompletedBaseline(fixture);

      expect(await fixture.coordinator.consume(invalid.frame)).toBe(false);
      expect(fixture.writes).toHaveLength(1);
      expect(fixture.resyncRequests).toEqual([invalid.reason]);
    });
  }

  test("stays desynchronized until a fresh baseline establishes a new epoch and cursor", async () => {
    const fixture = harness();
    await consumeCompletedBaseline(fixture);

    expect(
      await fixture.coordinator.consume(
        output({ sequenceStart: 11, sequenceEnd: 14 }),
      ),
    ).toBe(false);
    expect(
      await fixture.coordinator.consume(output()),
    ).toBe(false);
    expect(fixture.writes).toHaveLength(1);
    expect(fixture.resyncRequests).toEqual(["sequence_gap"]);

    const freshBaseline = fixture.coordinator.consume(
      baseline({
        streamEpoch: "epoch-b",
        sequenceEnd: 20,
        rows: 30,
        columns: 100,
        data: bytes("fresh baseline"),
      }),
    );
    await settle();
    expect(fixture.resizes).toEqual([
      [80, 24],
      [100, 30],
    ]);
    expect(fixture.writes).toHaveLength(2);
    fixture.writes[1]?.complete();
    expect(await freshBaseline).toBe(true);

    const freshOutput = fixture.coordinator.consume(
      output({
        streamEpoch: "epoch-b",
        sequenceStart: 20,
        sequenceEnd: 22,
        data: bytes("ok"),
      }),
    );
    await settle();
    expect(fixture.writes).toHaveLength(3);
    fixture.writes[2]?.complete();
    expect(await freshOutput).toBe(true);
    expect(fixture.resyncRequests).toEqual(["sequence_gap"]);
  });
});

describe("TerminalStreamCoordinator guest input", () => {
  test("UTF-8 encodes xterm onData without changing Unicode input", () => {
    const fixture = harness();

    expect(fixture.coordinator.onData("Aé🙂\r")).toBe(true);

    expect(fixture.sentInput).toHaveLength(1);
    expect(fixture.sentInput[0]?.kind).toBe("input");
    expect([...(fixture.sentInput[0]?.data ?? [])]).toEqual([
      ...bytes("Aé🙂\r"),
    ]);
  });

  test("preserves every 8-bit xterm onBinary code unit without UTF-8 expansion", () => {
    const fixture = harness();
    const binary = String.fromCharCode(0x00, 0x7f, 0x80, 0xff);

    expect(fixture.coordinator.onBinary(binary)).toBe(true);

    expect(fixture.sentInput).toHaveLength(1);
    expect(fixture.sentInput[0]?.kind).toBe("input");
    expect([...(fixture.sentInput[0]?.data ?? [])]).toEqual([
      0x00,
      0x7f,
      0x80,
      0xff,
    ]);
  });
});

describe("TerminalStreamCoordinator compatibility errors", () => {
  for (const mismatch of [
    {
      name: "share protocol",
      frame: baseline({ protocolVersion: PROTOCOL_VERSION + 1 }),
      code: "protocol_version_mismatch",
    },
    {
      name: "terminal",
      frame: baseline({ terminalVersion: TERMINAL_VERSION + 1 }),
      code: "terminal_version_mismatch",
    },
  ] as const) {
    test(`surfaces an explicit ${mismatch.name} version error instead of leaving a blank terminal`, async () => {
      const fixture = harness();

      expect(await fixture.coordinator.consume(mismatch.frame)).toBe(false);
      expect(fixture.writes).toEqual([]);
      expect(fixture.resyncRequests).toEqual([]);
      expect(fixture.coordinator.terminalError).toMatchObject({
        code: mismatch.code,
      });
      expect(
        fixture.coordinator.terminalError?.message.trim().length,
      ).toBeGreaterThan(0);
    });
  }
});
