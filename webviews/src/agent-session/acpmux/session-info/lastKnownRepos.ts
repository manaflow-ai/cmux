import { LastKnown } from "../../../lastKnown";
import type { CloudRepo } from "./CloudRepositoryPicker";

type KnownRepos = { repos: CloudRepo[]; connectUrl?: string };

/// The last list each chat's search answered (by chat and query), per request function (the host's
/// `postNative`; a gallery's or test's own stub keeps its own lists): the picker opened again draws
/// it at once, with no "Searching" line, and lists again behind it.
let lastReposByRequest = new WeakMap<object, LastKnown<KnownRepos>>();

export function knownRepos(request: object): LastKnown<KnownRepos> {
  let known = lastReposByRequest.get(request);
  if (!known) lastReposByRequest.set(request, (known = new LastKnown<KnownRepos>(16)));
  return known;
}

/// Drops every last-known list (tests).
export function resetLastKnownReposForTests(): void {
  lastReposByRequest = new WeakMap();
}
