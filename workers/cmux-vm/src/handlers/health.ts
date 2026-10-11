import { HttpApiBuilder } from "@effect/platform";
import { Effect } from "effect";
import { CmuxVmApi, Health } from "../api.ts";

export const healthHandlers = HttpApiBuilder.group(CmuxVmApi, "health", (handlers) =>
  handlers.handle("health", () => Effect.succeed(new Health({ ok: true }))),
);
