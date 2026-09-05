import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  IrohTrustBroker,
  makeIrohTrustBroker,
} from "./trustBroker";
import { IrohTrustBrokerConfig, IrohTrustBrokerConfigLive } from "./config";
import { IrohRepository, IrohRepositoryLive } from "./repository";
import { IrohRelayMinter, IrohRelayMinterLive } from "./relayMinter";
import { RelayRepository, RelayRepositoryLive } from "../relay/repository";

export const IrohTrustBrokerLive = Layer.effect(
  IrohTrustBroker,
  Effect.gen(function* () {
    return makeIrohTrustBroker(
      yield* IrohRepository,
      yield* IrohRelayMinter,
      yield* IrohTrustBrokerConfig,
      yield* RelayRepository,
    );
  }),
);

const IrohRelayMinterWithConfig = IrohRelayMinterLive.pipe(
  Layer.provide(IrohTrustBrokerConfigLive),
);

export const IrohTrustBrokerRuntime = IrohTrustBrokerLive.pipe(
  Layer.provide(Layer.mergeAll(
    IrohRepositoryLive,
    RelayRepositoryLive,
    IrohTrustBrokerConfigLive,
    IrohRelayMinterWithConfig,
  )),
);
