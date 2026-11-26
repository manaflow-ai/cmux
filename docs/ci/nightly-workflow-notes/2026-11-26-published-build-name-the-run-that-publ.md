# published-build: Name the run that published

Where: the `published-build` job in `.github/workflows/nightly.yml`, above `- name: Name the run that published`.

Anyone who may dispatch this workflow writes the input, and the tail checks out the record's build
commit with the Sparkle key. So the input only names the run: the API says what that run is, and the
record comes from its own artifact, which only its jobs can write.
