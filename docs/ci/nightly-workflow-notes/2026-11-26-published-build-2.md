# 2026-11-26-published-build-2

Above `- name: Name the run that published` (job `published-build`) in `.github/workflows/nightly.yml`.

Anyone who may dispatch this workflow writes the input, and the tail checks out the record's build
commit with the Sparkle key. So the input only names the run: the API says what that run is, and the
record comes from its own artifact, which only its jobs can write.
