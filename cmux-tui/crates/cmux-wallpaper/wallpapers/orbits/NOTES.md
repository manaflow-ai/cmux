# Orbits

- What moves: the dashes and dots ride their orbits and small bodies travel along them at Kepler-ish rates (slower farther out, a hashed irrational factor per orbit, so no shared period); the whole chart's apsidal axis precesses very slowly.
- The pointer is a mass: the field is sampled through a soft lens (radius 0.2 of the height), so the nearest orbits bend toward it; strength eases with presence (relaxes when it leaves) and grows a little once it rests. The central body is drawn unlensed and stays round.
- Look: hairline confocal conics (each with its own small tilt and eccentricity), solid/dashed/dotted or skipped by hash, every 5th heavier; an ordered-dither sphere; a dotted apsidal axis; static print grain. One orbit and its body in the accent.
- Cost: one loop of 5 candidate orbits (nearest from a shared base field, +-2). Per candidate ~60 ALU, 5 integer hashes, 1 pow, 1 atan2, 2 sin/cos pairs, 2 lengths; the body test is inline (no particle loop).
- Outside the loop: 2 log, 1 exp, 1 sin/cos pair, 1 sqrt, a 4x4 Bayer lookup by bit ops and one pixel hash. About 450 ALU ops and ~40 transcendentals per pixel; no noise octaves, no textures.
- Variants: Chart (default), Ephemeris (dense, near-circular, fewer bodies, lighter lines), Comet (sparse, eccentric, crossing orbits, faster).
