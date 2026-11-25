# Eclipse

- Reference: the eclipse rim glow in "5 Cinematic Motion Graphics You Should Know in After Effects" (Leo: "after effects level animations in your background").
- Look: a dark disc (the moon) over a glowing disc of the same radius set 5% of the radius off center, so only a thin rim shows, a crescent on one side (`exp(-dg / rimW)`, rimW 1.2% of the radius) and a faint ring all the way round. A soft bloom (`exp(-e / 0.32 R)`, strongest on the bright arc) and a wide halo (`exp(-e / 1.6 R)`) fall off from the rim.
- Rays: two streak patterns over the polar angle (frequency 9 phase-warped by frequency 4, frequency 23 warped by frequency 2), sharpened with pow 6 and 10, given uneven strength and reach by a product of frequency 3 and 5 sines, and a slow outward stream along the radius. Every angular frequency is a whole number, so there is no seam where atan2 wraps.
- Moves: the bright arc turns (0.12 rad per unit time plus a slow wobble), the corona breathes (two sines, +-18%), the rays drift. Speed scales all of it.
- Placement: center at 0.76 of the width and 0.30 of the height by default (upper right), radius 0.16 of the height, so it sits away from where code usually is.
- Theme: dark: paper ground, disc at 55% of the paper (darker), corona in the accent, rim core halfway from the accent to white. Light: paper ground, disc 14% toward the ink, corona the accent 20% toward the paper, rim a deeper accent (82%). Mixed in a sqrt space; the corona is mixed at most 45% and the rim 80%, so the contrast stays low.
- Pointer: parallax, the disc shifts up to 2.5% (times `parallax`) of the pointer's offset from the window center, the other way, eased by `presence.x`.
- Agents (`agents: true`): the level brightens the rim (+70%), widens it (+60%) and lifts the corona (+30%), times `activity`. A new event sends a flare from an angle set by its count, running along the rim at 0.9 rad/s with a short tail, fading as `exp(-0.7 * activity.y)`. A still shows level 0.35 and no flare.
- Banding: a triangular dither one 8-bit step wide, new each frame; checked at 12x contrast on the bloom: no bands.
- Cost: no loops. 1 atan2, 2 length, about 14 sin/cos (one of them a hash), 10 exp, 2 pow, 2 integer hashes; about 190 ALU ops and ~30 transcendentals per pixel, constant in size and input. `scale: 0.5`: the rim is the only fine detail (1.2% of the radius, about 2 px at 0.5 on a 2x screen). No textures.
- Variants: Corona (default, blue), Solar (amber, larger, more corona), Faint (violet, small, dim, slower).
