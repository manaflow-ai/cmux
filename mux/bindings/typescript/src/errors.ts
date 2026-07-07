export class MuxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}

export class MuxCommandError extends MuxError {
  readonly commandId: unknown;
  readonly response: unknown;

  constructor(message: string, commandId?: unknown, response?: unknown) {
    super(message);
    this.commandId = commandId;
    this.response = response;
  }
}

export class MuxConnectionError extends MuxError {}
export class MuxProtocolError extends MuxError {}
export class MuxTimeoutError extends MuxError {}
