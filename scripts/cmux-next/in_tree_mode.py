"""In-tree Chromium pages for the harnesses (plans/cmux-next/in-tree-pages.md).

The app decides the mode once at launch: `CMUX_IN_TREE_PAGES` (1 or 0) first, then `browser.inTreePages` in the
build's debug-tunables.json, then the build's default (on for a dev build tagged `in-tree-pages...`). A harness picks
the mode with `--in-tree on|off` (default `keep`: whatever the build decides), which sets the environment variable for
every launch it makes, its children's included (bench_launch.BenchApp passes it on). After a launch it reads the mode
back from `debug.cef` `in_tree` and refuses a run whose app reports another mode, so an OFF-versus-IN comparison on
one build is what it says.

    import in_tree_mode
    in_tree_mode.add_argument(parser)
    opts = parser.parse_args()
    in_tree_mode.apply(opts.in_tree)            # before the first launch
    ...
    mode = in_tree_mode.read(rpc)                # after the app came up
    problem = in_tree_mode.mismatch(opts.in_tree, mode)
    if problem: sys.exit(problem)
"""
import os

ENV = "CMUX_IN_TREE_PAGES"
KEY = "browser.inTreePages"
CHOICES = ("keep", "on", "off")


def add_argument(parser):
    parser.add_argument("--in-tree", dest="in_tree", choices=CHOICES, default="keep",
                        help="in-tree Chromium pages for every launch: on, off, or keep (the build's own decision)")


def apply(choice, env=None):
    """Sets the switch for this process's launches (and `env`, a launch environment a script builds itself)."""
    if choice == "keep":
        value = os.environ.get(ENV)
    else:
        value = "1" if choice == "on" else "0"
        os.environ[ENV] = value
    if env is not None and value is not None:
        env[ENV] = value
    return env


def read(rpc):
    """The app's mode, `debug.cef` `in_tree`: off, pending, on, `unsupported_fork: ...`, or None (a build without it)."""
    reply = rpc("debug.cef") or {}
    return reply.get("in_tree") if isinstance(reply, dict) else None


def mismatch(choice, status):
    """Why a run asked for `choice` does not have it (None when it does, or when the harness kept the build's mode)."""
    if choice == "on" and status != "on":
        return f"asked for in-tree pages, the app reports in_tree={status!r}"
    if choice == "off" and status not in ("off", None):
        return f"asked for in-tree pages off, the app reports in_tree={status!r}"
    return None


def record(choice, status):
    """The fields a harness's JSON keeps for its run."""
    return {"in_tree_requested": choice, "in_tree": status}
