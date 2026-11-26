# release-compile: Checkout

Where: the `release-compile` job in `.github/workflows/cmux-next.yml`, above `- name: Checkout`.

A fetch that breaks off is tried again by the action from nothing; bounded so a stalled transfer
moves on to the retry below instead of holding the Mac to the job's 60 min.
