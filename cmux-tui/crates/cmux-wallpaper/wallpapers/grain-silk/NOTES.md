# Grain and Silk

- Moves: diagonal satin folds whose line bends slowly (curvature), whose phase is frequency-modulated (folds of varying width) and whose amplitude swells and fades along their length, over a broad billow. All rates are incommensurate (0.017 to 0.061 rad per unit time), so no period shows.
- Light: falls across the folds from the upper right. Tone is lambert plus height occlusion, soft-saturated into trough / midtone / ridge, mixed in a sqrt (perceptual) space: light theme troughs reach ink at ~40%, dark theme ridges ~42% and streaks ~62% toward ink, dark troughs sit below paper. Each lit shoulder carries a narrow anisotropic streak (it depends only on the slope across the fold, so it runs along the fold).
- Grain: luminance only, new each frame: triangular per-pixel hash plus a 2x2 clump hash, stronger in shadows.
- Pointer: the fold under it lifts (amplitude grows in a Gaussian, eased by `presence.x`), its streak widens and takes the accent; the accent appears nowhere else.
- Fast motion: rings spread from a short trail (the last 0.15 s of velocity, at most 0.3 units); they decay with the host's smoothed velocity and `exp(-0.6 * presence.y)`, still visible ~400 ms after a fast pass.
- Variants: Satin (default), Crepe (fine dense folds, heavy grain, amber), Drape (broad slow folds, high sheen, violet).
- Cost: no loops. Height is evaluated 3 times (forward-difference gradient), each 7 sin, 1 exp (lift), 1 exp + 1 sqrt (ripple) and a segment distance; then 1 normalize, 1 exp (accent falloff), 1 exp (streak), 1 inverseSqrt, 3 integer hashes. About 230 ALU ops and ~26 transcendentals per pixel, constant regardless of size or pointer.
