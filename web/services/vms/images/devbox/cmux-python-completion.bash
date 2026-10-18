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
    # package. Import the helpers with every cwd entry off sys.path (-c adds
    # "", and an empty PYTHONPATH entry adds the absolute cwd) so a checkout's
    # pkgutil.py cannot load, then resolve each dotted level with PathFinder
    # instead of importing it. Namespace levels need their parent in
    # sys.modules; a stub with __path__ supplies it without running code.
    COMPREPLY+=($(compgen -W "$("${1:-python}" -c '
import os, sys
saved = sys.path[:]
cwd = os.path.realpath(os.getcwd())
sys.path[:] = [p for p in saved if p and os.path.realpath(p) != cwd]
import importlib.machinery, pkgutil, types
sys.path[:] = [p for p in saved if p]
cur = sys.argv[1]
if "." in cur:
    parts = cur.split(".")[:-1]
    paths = sys.path
    for i in range(len(parts)):
        name = ".".join(parts[:i + 1])
        spec = importlib.machinery.PathFinder.find_spec(name, paths)
        paths = list(spec.submodule_search_locations or ()) if spec else None
        if not paths:
            break
        stub = types.ModuleType(name)
        stub.__path__ = paths
        sys.modules.setdefault(name, stub)
    mods = pkgutil.iter_modules(paths, ".".join(parts) + ".") if paths else ()
else:
    mods = pkgutil.iter_modules()
for mod in mods:
    print(mod[1])
' "$cur" 2>/dev/null)" -- "$cur"))
}
