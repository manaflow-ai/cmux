# 2026-11-27-release-compile-2

Above `- name: Checkout` (job `release-compile`) in `.github/workflows/cmux-next.yml`.

A fetch that breaks off is tried again by the action from nothing; bounded so a stalled transfer
moves on to the retry below instead of holding the Mac to the job's 60 min.
