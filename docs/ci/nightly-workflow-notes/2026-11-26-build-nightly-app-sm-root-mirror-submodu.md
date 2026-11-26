# build-nightly-app: sm_root=${mirror%/*}/submodules

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `sm_root=${mirror%/*}/submodules`.

Run 45782377330 timed out here (600 s, 3 tries) reading the submodules from github.com. A mini keeps
one bare mirror per submodule at submodules/NAME.git beside cmux.git (glaeda-git-mirror: each pin as
refs/pins/<sha>, depth 1, glaeda.url naming its GitHub URL). Each submodule (nested too) whose commit
one holds is read from it, through this step's environment only; the rest from github.com.
