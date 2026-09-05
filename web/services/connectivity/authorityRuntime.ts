import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  ConnectivityAuthority,
  makeConnectivityAuthority,
} from "./authority";
import { IrohTrustBrokerRuntime } from "../iroh/trustBrokerRuntime";
import { IrohTrustBroker } from "../iroh/trustBroker";

/** Web/Vercel runtime wiring kept separate from the runtime-neutral authority.
 * The Cloudflare Worker imports `makeConnectivityAuthority` directly and must
 * not evaluate the Next env module or Vercel database adapter. */
export const ConnectivityAuthorityLive: Layer.Layer<
  ConnectivityAuthority,
  never,
  IrohTrustBroker
> = Layer.effect(
  ConnectivityAuthority,
  Effect.gen(function* () {
    return makeConnectivityAuthority(yield* IrohTrustBroker);
  }),
);

export const ConnectivityAuthorityRuntime: Layer.Layer<ConnectivityAuthority, never, never> =
  ConnectivityAuthorityLive.pipe(
    Layer.provide(IrohTrustBrokerRuntime),
  );
