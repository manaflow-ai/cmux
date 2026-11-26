# decide: Shadow the app-input digest

Where: the `decide` job in `.github/workflows/nightly.yml`, above `- name: Shadow the app-input digest`.

Shadow only (clean-sheet CI RFD hq#26225): would a build add nothing because no app input changed since the last
published commit? Reports app_input_digest and would_reuse; decides nothing, cannot fail the job.
