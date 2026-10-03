# python/python3 completion override, installed under
# /usr/local/share/bash-completion/completions (searched before /usr/share).
# Ubuntu's bash-completion 2.11 helper switches to pkgutil.walk_packages()
# once the word after `-m` contains a dot, which imports every installed
# package: about 5 s on the base image's site-packages. ble.sh runs this
# completion for ghost text after each keystroke, so `python -m http.` stalled
# typing. Keep the stock completion and list only the parent package's
# submodules, which imports at most that one package.
# Without the stock file there is no `complete` registration to amend; fail
# so the loader moves on to the next search directory.
[ -r /usr/share/bash-completion/completions/python ] || return 1
. /usr/share/bash-completion/completions/python

_python_modules()
{
    COMPREPLY+=($(compgen -W "$("${1:-python}" -c '
import importlib.util, pkgutil, sys
cur = sys.argv[1]
if "." in cur:
    parent = cur.rsplit(".", 1)[0]
    try:
        spec = importlib.util.find_spec(parent)
    except Exception:
        spec = None
    paths = spec.submodule_search_locations if spec else None
    mods = pkgutil.iter_modules(paths, parent + ".") if paths else ()
else:
    mods = pkgutil.iter_modules()
for mod in mods:
    print(mod[1])
' "$cur" 2>/dev/null)" -- "$cur"))
}
