# prepare-nightly-variant: *download-signing-inputs-paralle

Where: the `prepare-nightly-variant` job in `.github/workflows/nightly.yml`, above `- *download-signing-inputs-paralle`.

download-artifact reads each blob over one connection. Fetch all three
signing inputs over ranged HTTP concurrently, while retaining the
action downloads as per-artifact fallbacks if a ranged request fails.
