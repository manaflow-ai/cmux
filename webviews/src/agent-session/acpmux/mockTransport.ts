type MockTransport = typeof import("./mock");

let prepared: MockTransport | undefined;

// Mock entry points prepare the daemon before mounting. Reading it synchronously keeps the
// ready handshake and connection in one turn; even an already loaded import() would yield.
export function prepareMockTransport(transport: MockTransport): void {
  prepared = transport;
}

export function preparedMockTransport(): MockTransport | undefined {
  return prepared;
}
