import { handle, type Deps } from "./app";
import { createDb } from "./db";
import type { Env } from "./env";

export { SignalRoom } from "./signal";

function deps(env: Env): Deps {
  const room = (userId: string) => env.SIGNAL_ROOM.get(env.SIGNAL_ROOM.idFromName(userId));
  return {
    db: createDb(env),
    onlineHostIds: (userId) => room(userId).onlineHostIds(),
    disconnect: (userId, hostId) => room(userId).disconnect(hostId),
    connectSignal: (userId, request) => room(userId).fetch(request),
  };
}

export default {
  fetch(request, env) {
    return handle(request, env, deps(env));
  },
} satisfies ExportedHandler<Env>;
