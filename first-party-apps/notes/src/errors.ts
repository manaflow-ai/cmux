// Errors that reach callers with a stable code. The runtime reports a thrown
// CmuxError to command callers (CLI, MCP) as {code, message}; any other error
// becomes "command.failed". The generated typings declare CmuxError without its
// (code, message) constructor (README, gaps), hence the cast.

type CmuxErrorConstructor = new (code: string, message: string, details?: unknown, retryable?: boolean) => CmuxError

export const appError = (code: string, message: string): CmuxError => new (CmuxError as unknown as CmuxErrorConstructor)(code, message)
