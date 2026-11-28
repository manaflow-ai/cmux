# 2026-11-28-dispatch-published-in-ci-routing-agent

Where: `.github/workflows/nightly.yml`, job `dispatch-published-in`, step "ci-routing-agent": above `- name: Read the feed back before saying published`.

A run that says published reads the live feeds first: an unmoved feed fails here, red, and a refused build (nightly-next-one reds a real refusal) asks for no post-publication run (2026-11-25, run 45607031207).
