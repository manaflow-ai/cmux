# Migration: model-based, old -> new on random states

**Proves:** for every reachable old state, the migrated state means the same thing. A handful of hand-written
cases misses the state nobody thought of; random states built from the old model find it.

**The minimal check:**
1. A generator of random valid old states (sizes up to realistic scale; empty, one, many; unicode; the maximum
   lengths). Seeded, so a failure reproduces.
2. An oracle: the property the migration must keep, written against the OLD model (e.g. "the same workspaces in
   the same order, each with its chats"), or the old code path itself when it still exists.
3. Run migrate on N random states (N = 200-1,000, under a second); assert the property; assert migrate is
   idempotent (migrating a migrated state changes nothing); assert the new reader loads it.
4. Keep one failing seed as a fixture when one is found.
5. Database migrations (web/db, backend/db, workers): apply up on a copy of a realistic schema snapshot, then down
   if the tool supports it; `scripts/check-backend-migration-flow.py` checks the backend's order.

```python
import random, unittest

class MigrationModelTest(unittest.TestCase):
    def test_old_to_new_keeps_meaning(self):
        for seed in range(300):
            rng = random.Random(seed)
            old = random_old_state(rng, workspaces=rng.choice([0, 1, 7, 1100]))
            new = migrate(old)
            self.assertEqual(view_old(old), view_new(new), f"seed {seed}")
            self.assertEqual(migrate_new(new), new, f"seed {seed}: not idempotent")
```

The same shape tests a rewrite of a hot path: the old slow implementation is the oracle, the new one the subject.
Copy from: `tests/test_bench_relevance_map.py` (`Scan` is the oracle for `Index`).
