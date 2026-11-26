# republish-nightly-next: Upload the republished build's Chromium runtime pack

Where: the `republish-nightly-next` job in `.github/workflows/nightly.yml`, above `- name: Upload the republished build's Chromium runtime pack`.

publish-nightly reads the pack by this run's name when the source build has one (its cef
output), whatever CMUX_NEXT_CEF_ON_DEMAND says now: the app's pin names that pack.
