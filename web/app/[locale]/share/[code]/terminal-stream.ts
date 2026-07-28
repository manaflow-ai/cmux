export type TerminalCompatibilityError = {
  readonly code:
    | "protocol_version_mismatch"
    | "terminal_version_mismatch"
    | "terminal_runtime_mismatch";
  readonly message: string;
};

export type TerminalBaselineFrame = {
  readonly kind: "baseline";
  readonly protocolVersion: number;
  readonly terminalVersion: number;
  readonly streamEpoch: string;
  readonly sequenceEnd: number | bigint;
  readonly rows: number;
  readonly columns: number;
  readonly data: Uint8Array;
};

export type TerminalOutputFrame = {
  readonly kind: "output";
  readonly streamEpoch: string;
  readonly sequenceStart: number | bigint;
  readonly sequenceEnd: number | bigint;
  readonly data: Uint8Array;
};

export type TerminalInputFrame = {
  readonly kind: "input";
  readonly data: Uint8Array;
};

export type TerminalStreamFrame =
  | TerminalBaselineFrame
  | TerminalOutputFrame;

type TerminalStreamOptions = {
  readonly protocolVersion: number;
  readonly terminalVersion: number;
  readonly resize: (columns: number, rows: number) => void;
  readonly write: (data: Uint8Array, onConsumed: () => void) => void;
  readonly onResyncRequested: (reason: string) => void;
  readonly sendTerminalInput: (frame: TerminalInputFrame) => boolean;
};

const utf8Encoder = new TextEncoder();

function sequence(value: number | bigint): bigint | null {
  if (typeof value === "bigint") return value >= BigInt(0) ? value : null;
  return Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null;
}

/**
 * Owns the byte-stream invariants between one host PTY and one xterm parser.
 *
 * Calls to `consume` are serialized all the way through xterm's write
 * callback. A caller can therefore use the resolved promise as the delivery
 * ACK boundary without acknowledging bytes that xterm has not parsed yet.
 */
export class TerminalStreamCoordinator {
  terminalError: TerminalCompatibilityError | null = null;

  private readonly options: TerminalStreamOptions;
  private tail: Promise<void> = Promise.resolve();
  private synchronized = false;
  private resyncRequested = false;
  private streamEpoch: string | null = null;
  private nextSequence = BigInt(0);

  constructor(options: TerminalStreamOptions) {
    this.options = options;
  }

  consume(frame: TerminalStreamFrame): Promise<boolean> {
    const result = this.tail.then(
      () => this.consumeNext(frame),
      () => this.consumeNext(frame),
    );
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  onData(data: string): boolean {
    if (data.length === 0) return false;
    return this.options.sendTerminalInput({
      kind: "input",
      data: utf8Encoder.encode(data),
    });
  }

  onBinary(data: string): boolean {
    if (data.length === 0) return false;
    const bytes = new Uint8Array(data.length);
    for (let index = 0; index < data.length; index += 1) {
      const byte = data.charCodeAt(index);
      if (byte > 0xff) return false;
      bytes[index] = byte;
    }
    return this.options.sendTerminalInput({ kind: "input", data: bytes });
  }

  private async consumeNext(frame: TerminalStreamFrame): Promise<boolean> {
    if (this.terminalError) return false;
    if (frame.kind === "baseline") return this.consumeBaseline(frame);
    return this.consumeOutput(frame);
  }

  private async consumeBaseline(
    frame: TerminalBaselineFrame,
  ): Promise<boolean> {
    if (frame.protocolVersion !== this.options.protocolVersion) {
      this.terminalError = {
        code: "protocol_version_mismatch",
        message: "protocol_version_mismatch",
      };
      return false;
    }
    if (frame.terminalVersion !== this.options.terminalVersion) {
      this.terminalError = {
        code: "terminal_version_mismatch",
        message: "terminal_version_mismatch",
      };
      return false;
    }
    const sequenceEnd = sequence(frame.sequenceEnd);
    if (
      sequenceEnd === null ||
      frame.streamEpoch.length === 0 ||
      !Number.isInteger(frame.rows) ||
      frame.rows <= 0 ||
      frame.rows > 0xffff ||
      !Number.isInteger(frame.columns) ||
      frame.columns <= 0 ||
      frame.columns > 0xffff
    ) {
      this.desynchronize("invalid_baseline");
      return false;
    }

    this.options.resize(frame.columns, frame.rows);
    const consumed = await this.write(frame.data);
    if (!consumed) {
      this.desynchronize("terminal_write_failed");
      return false;
    }
    this.streamEpoch = frame.streamEpoch;
    this.nextSequence = sequenceEnd;
    this.synchronized = true;
    this.resyncRequested = false;
    return true;
  }

  private async consumeOutput(frame: TerminalOutputFrame): Promise<boolean> {
    if (!this.synchronized || this.streamEpoch === null) {
      this.desynchronize("baseline_required");
      return false;
    }
    if (frame.streamEpoch !== this.streamEpoch) {
      this.desynchronize("stream_epoch_mismatch");
      return false;
    }
    const sequenceStart = sequence(frame.sequenceStart);
    const sequenceEnd = sequence(frame.sequenceEnd);
    if (
      sequenceStart === null ||
      sequenceEnd === null ||
      sequenceStart !== this.nextSequence ||
      sequenceEnd < sequenceStart ||
      sequenceEnd - sequenceStart !== BigInt(frame.data.byteLength)
    ) {
      this.desynchronize("sequence_gap");
      return false;
    }

    const consumed = await this.write(frame.data);
    if (!consumed) {
      this.desynchronize("terminal_write_failed");
      return false;
    }
    this.nextSequence = sequenceEnd;
    return true;
  }

  private write(data: Uint8Array): Promise<boolean> {
    return new Promise((resolve) => {
      let completed = false;
      const onConsumed = (): void => {
        if (completed) return;
        completed = true;
        resolve(true);
      };
      try {
        this.options.write(data, onConsumed);
      } catch {
        completed = true;
        resolve(false);
      }
    });
  }

  private desynchronize(reason: string): void {
    this.synchronized = false;
    this.streamEpoch = null;
    if (this.resyncRequested) return;
    this.resyncRequested = true;
    this.options.onResyncRequested(reason);
  }
}
