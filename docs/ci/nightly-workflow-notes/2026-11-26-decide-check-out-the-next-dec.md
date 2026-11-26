# decide: Check out the NEXT decision helper

Where: the `decide` job in `.github/workflows/nightly.yml`, above `- name: Check out the NEXT decision helper`.

NEXT's decision reads release metadata, not the app tree. Main's build-input
classifier still needs the full checkout above, including tracked referrers.
