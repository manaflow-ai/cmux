# Peer recovery: deadline, aliases and persisted token ownership

Owner notice for PL-acpmux. Leo asked: “the direct-path redial deadline; refusing a duplicate WG key; the token race on the same URL. Each fix gets a test that reproduces the bug.”

A direct path that has already connected gets a four-second budget for its next dial and WebSocket upgrade together (previously thirty seconds). Cold connects keep their configured budget, and a configured shorter budget still wins. Two configured names for one authenticated key share one mesh peer and retain both endpoint candidates; distinct keys still cannot own overlapping overlay addresses.

A persisted token writer now belongs to the registered peer generation. Preparation only reads the saved entry. Registration changes an atomic generation under the registry lock; the file update runs after that lock is released. A retired peer can neither erase nor overwrite its replacement's entry, even for the same name and URL. Writer gates leave when their last cache drops. The file format and transport defaults are unchanged.

Detectors: `a_direct_redial_has_its_own_deadline_through_the_websocket_upgrade`, `aliases_of_one_wireguard_key_share_one_mesh_peer`, and `a_replaced_cache_cannot_erase_or_overwrite_the_same_urls_new_tokens`. All three fail on the test-only head `0cb654b5163d87e44c6935c9ffbb44e895c27b83` in Linux run [43306281306](https://github.com/manaflow-ai/cmux/actions/runs/43306281306). Additional regressions cover reverse preparation/registration order, retiring writer cleanup, and overlapping addresses owned by distinct keys.

Review and verification are tracked in [#42171](https://github.com/manaflow-ai/cmux/pull/42171). This changes the shared peer daemon, with no UI or deployment-switch change; merging alone does not establish that a running app has received it.
