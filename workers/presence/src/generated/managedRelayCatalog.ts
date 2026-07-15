/**
 * Generated from config/iroh/managed-relay-catalog.json.
 *
 * Fleet rotations are add-before-remove. Bump sequence and add first, deploy
 * both server consumers, wait one signed-policy lifetime, then bump sequence
 * again and remove. Run web/tools/generate-managed-iroh-relay-catalog.ts after
 * every edit. Signing keys and relay credentials never belong in this file.
 */
export const MANAGED_IROH_RELAY_CATALOG = {
  "version": 1,
  "sequence": 2,
  "relays": [
    {
      "id": "usc1",
      "provider": "cmux",
      "region": "US Central",
      "url": "https://usc1.relay.cmux.dev/"
    },
    {
      "id": "usw1",
      "provider": "cmux",
      "region": "US West",
      "url": "https://usw1.relay.cmux.dev/"
    },
    {
      "id": "use4",
      "provider": "cmux",
      "region": "US East",
      "url": "https://use4.relay.cmux.dev/"
    },
    {
      "id": "euw4",
      "provider": "cmux",
      "region": "Europe West",
      "url": "https://euw4.relay.cmux.dev/"
    },
    {
      "id": "apne1",
      "provider": "cmux",
      "region": "Asia Pacific Northeast",
      "url": "https://apne1.relay.cmux.dev/"
    },
    {
      "id": "apse1",
      "provider": "cmux",
      "region": "Asia Pacific Southeast",
      "url": "https://apse1.relay.cmux.dev/"
    },
    {
      "id": "ape1",
      "provider": "cmux",
      "region": "Asia Pacific East",
      "url": "https://ape1.relay.cmux.dev/"
    }
  ]
} as const;

/** Exact managed relay origins derived from the canonical catalog. */
export const MANAGED_IROH_RELAY_URLS = MANAGED_IROH_RELAY_CATALOG.relays.map(
  (relay) => relay.url,
);
