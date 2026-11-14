title: Switch Cloud backends without rebuilding
category: improved
docs: https://cmux.com/docs/next/cli

Launch the same app with `--cloud-backend staging` or `--cloud-backend prod`, or use `cmux cloud env set staging` in a DEV or nightly build. Backend configuration is fetched at runtime, with separate sign-in storage per backend.
