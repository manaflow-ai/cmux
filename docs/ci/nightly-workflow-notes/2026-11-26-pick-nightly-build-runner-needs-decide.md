# pick-nightly-build-runner: needs: [decide]

Where: the `pick-nightly-build-runner` job in `.github/workflows/nightly.yml`, above `needs: [decide]`.

Beside resolve-nightly-cmux-tui-client, not after it: the pick reads only decide's outputs, and build-nightly-app
still needs both. One runner pickup off the path to the app build (nightly-30min; run 41941610932 waited 5.9 min
here after resolve). It keeps resolve's gate, so it runs only when resolve does.
