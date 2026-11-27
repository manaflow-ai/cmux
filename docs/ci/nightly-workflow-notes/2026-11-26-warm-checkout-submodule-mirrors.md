# Warm nightly-next checkout: submodules from the fleet mirrors

Where: the warm nightly-next builder's "Checkout build ref" step in `.github/workflows/nightly.yml`.

Submodules come from the fleet's mirrors too (run 45782377330: `git submodule update` timed out at 600 s on all three tries, reading ghostty, ghostty-next and homebrew-cmux from github.com). A mini keeps one bare mirror per cmux submodule at submodules/NAME.git beside cmux.git (glaeda-git-mirror's submodule pass, glaeda#2843: each pin as refs/pins/<sha>, depth 1, `glaeda.url` naming its GitHub URL). For each submodule, nested ones included, the kept mirror whose glaeda.url is the submodule's URL and that holds the gitlink commit replaces its github.com URL through `url.file://MIRROR.insteadOf` in the step's environment, with `protocol.file.allow=always`; file:// keeps `--depth=1`. Any other submodule is read from github.com with the job's token. Test: tests/test_nightly_warm_checkout_submodules_from_mirror.py.
