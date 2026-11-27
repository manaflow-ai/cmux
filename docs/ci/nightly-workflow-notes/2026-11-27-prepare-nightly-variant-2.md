# 2026-11-27-prepare-nightly-variant-2

Above `- *download-signing-inputs-paralle` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

download-artifact reads each blob over one connection. Fetch all three
signing inputs over ranged HTTP concurrently, while retaining the
action downloads as per-artifact fallbacks if a ranged request fails.
