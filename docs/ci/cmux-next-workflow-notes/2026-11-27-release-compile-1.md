# 2026-11-27-release-compile-1

Above `- name: Borrow the host's git mirror` (job `release-compile`) in `.github/workflows/cmux-next.yml`.

Before any checked-out code: the checkout below borrows this host's git mirror (glaeda-git-mirror:
main, feat-cmux-next and nightly-next, fetched every 60 s; /Users/Shared/cmux-build-fleet/git/cmux.git)
through objects/info/alternates, so its depth-2 fetch from GitHub sends only what the mirror lacks
(the PR's own commits), not the whole tree. In the two days to 2026-11-26 10:35Z, 32 runs of this job
spent over 20 min in Checkout (26 Mac-hours), and 14 of the 29 runs cut at 60 min spent 35-60 min
there: a fresh workspace's whole-tree fetch from the fleet's shared address broke off ("curl 92
HTTP/2 stream ... CANCEL", "early EOF") and was fetched again from nothing, three times. The same
borrow as nightly.yml's warm checkout and the Linux pool's mirror checkout (cmux-next-fast-gates.yml),
with the same glaeda-mirror-borrow.json record. No mirror, or one glaeda has not verified or is
repairing: nothing changes.
