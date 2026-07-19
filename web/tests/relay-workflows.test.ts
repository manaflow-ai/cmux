import { describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import type { RelayCatalog } from "../services/relay/model";
import {
  RelayRepository,
  type RelayRepositoryShape,
} from "../services/relay/repository";
import { signedRelayPolicy } from "../services/relay/workflows";

const catalog: RelayCatalog = {
  version: 1,
  sequence: 8,
  relays: [{
    id: "managed-current",
    provider: "cmux",
    region: "US West",
    url: "https://usw1.relay.cmux.dev/",
  }],
};

describe("relay workflows", () => {
  test("issues the current signed catalog when an account selection is stale", async () => {
    const { privateKey } = generateKeyPairSync("ed25519");
    let acceptedInput: unknown;
    const repository: RelayRepositoryShape = {
      acceptCatalog: (input) => Effect.sync(() => { acceptedInput = input; }),
      getPreference: () => Effect.succeed({
        preference: {
          mode: "managed",
          selectedManagedRelayIds: ["managed-removed"],
          customRelays: [],
        },
        revision: 4,
      }),
      putPreference: () => Effect.die("unexpected preference write"),
    };

    const result = await Effect.runPromise(
      signedRelayPolicy("account-a", {
        catalog,
        signingKey: { kid: "relay-policy-test", key: privateKey },
        nowSeconds: 1_700_000_000,
        jti: "01890f47-9ff8-7cc2-98b3-2fefdbb4312c",
      }).pipe(Effect.provide(Layer.succeed(RelayRepository, repository))),
    );

    expect(acceptedInput).toEqual({
      catalog,
      nowSeconds: 1_700_000_000,
    });
    expect(result.payload.relays).toEqual(catalog.relays);
    expect(result.preference).toEqual({
      mode: "managed",
      selectedManagedRelayIds: ["managed-removed"],
      customRelays: [],
    });
    expect(result.preferenceRevision).toBe(4);
  });
});
