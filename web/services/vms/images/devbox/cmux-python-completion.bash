# python/python3 completion override, installed under
# /usr/local/share/bash-completion/completions (searched before /usr/share).
# Ubuntu's bash-completion 2.11 helper switches to pkgutil.walk_packages()
# once the word after `-m` contains a dot, which imports every installed
# package: about 5 s on the base image's site-packages. ble.sh runs this
# completion for ghost text after each keystroke, so `python -m http.` stalled
# typing. Keep the stock completion and list only the parent package's
# submodules without importing anything.
# Without the stock file there is no `complete` registration to amend; fail
# so the loader moves on to the next search directory.
[ -r /usr/share/bash-completion/completions/python ] || return 1
. /usr/share/bash-completion/completions/python

_python_modules()
{
    # Python code here runs on every keystroke, so it must not execute any
    # package: drop -c's current-directory entry (a checkout's pkgutil.py or
    # packages would otherwise load) and resolve each dotted level with
    # PathFinder instead of importing it.
    COMPREPLY+=($(compgen -W "$("${1:-python}" -c '
import sys
if sys.path and sys.path[0] == "":
    del sys.path[0]
import importlib.machinery, pkgutil
cur = sys.argv[1]
if "." in cur:
    parts = cur.split(".")[:-1]
    paths = sys.path
    for i in range(len(parts)):
        spec = importlib.machinery.PathFinder.find_spec(".".join(parts[:i + 1]), paths)
        paths = spec.submodule_search_locations if spec else None
        if not paths:
            break
    mods = pkgutil.iter_modules(paths, ".".join(parts) + ".") if paths else ()
else:
    mods = pkgutil.iter_modules()
for mod in mods:
    print(mod[1])
' "$cur" 2>/dev/null)" -- "$cur"))
}
