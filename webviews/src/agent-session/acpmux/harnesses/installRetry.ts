// An install command that survives a dropped network (first-run finding 6). Seam only: the
// command runs as it is, once.

/// The line the wrapped command prints when it waits for the network.
export const OFFLINE_MARK = "cmux-install: waiting for the network";
/// The line it prints when the network is back and the install runs again.
export const RETRY_MARK = "cmux-install: running the install again";

export type NetworkRetry = {
  /// A shell command that exits 0 while the installer's server is reachable.
  online?: string;
  pollSeconds?: number;
  waitSeconds?: number;
};

export const withNetworkRetry = (command: string, _options: NetworkRetry = {}): string => command;
