# 2026-11-24-app-compile-fleet-3

Above `word="$(python3 "$reader" --sha "$REF" --repo "$GITHUB_REPOSITORY" --pr "$PR" --phase app-debug \` in the step `Compile-check the app at the pull request's head on the build fleet`'s script (job `app-compile-fleet`) in `.github/workflows/cmux-next.yml`.

The reader's reason line (stderr) names why a red failed (the build fleet job and its first error).
