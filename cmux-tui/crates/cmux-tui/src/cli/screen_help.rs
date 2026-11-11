//! `cmux screen --help`.

pub(super) const SCREEN_HELP: &str = "\
USAGE
  cmux screen list
  cmux screen create [--workspace <selector>] [--name <value>] [--focus]
    [--correlation-key <value>] [--shell <script> | -- <argv...>]
  cmux screen <selector> show|focus|close
  cmux screen <selector> close [--keep-terminals]
  cmux screen <selector> close --others|--to-right|--to-left|--all [--include-pinned]
    [--keep-terminals]
  cmux screen <selector> rename <name>|--name <name>
  cmux screen <selector> pin|unpin
  cmux screen <selector> update [--pinned <bool>] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon]
  cmux screen <selector> move --index <n>
  cmux screen <selector> layout export
  cmux screen <selector> layout undo [--confirm-close]
    [--confirmation-token <value>]
  cmux screen <selector> column <split_…> update [--dock <bool>]
    [--edge left|right|top|bottom] [--mode docked|overlay] [--width <fraction>]
    [--pinned true] [--allow-tabs <bool>]
  cmux screen <selector> pane ...
  cmux screen group list [--workspace <selector>]
  cmux screen group create --screens <screen_…,...> [--name <value>] [--color <color>]
  cmux screen group <group> show|ungroup
  cmux screen group <group> update [--name <value>] [--color <color>]
    [--icon <icon>|--clear-icon] [--collapse|--expand]
  cmux screen group <group> add --screens <screen_…,...>
  cmux screen group remove --screens <screen_…,...>

create adds the screen to the current workspace (or --workspace) and keeps
the focus where it is unless --focus is given.
A bulk close (--others, --to-right, --to-left, --all) is one closed group
that `cmux closed reopen` restores whole; it keeps pinned screens unless
--include-pinned.
close ends the terminals it leaves with no tab, except one marked keep and the
caller's own, and names the ones still running; --keep-terminals leaves them
all running.
column update --pinned true makes a docked column the pinned dock (Home's):
its first tab stays and it is never undocked; it takes no other tab unless
--allow-tabs true. Pinning is one way.
Pinned screens sort first and leave their group. A group has no color until
one is given: grey, blue, red, yellow, green, pink, purple, cyan, orange, a
custom #RRGGBB, or none. A group
icon is one emoji, an SF Symbol name, or a stored image:sha256-<hex> or
svg:sha256-<hex> asset; --clear-icon removes it.

SELECTORS
  <selector> is an id (screen_…), caller, current, or an exact name. Prefix
  name: to a name that looks like an id or a command word.
  caller is the object this command runs in: the cmux terminal or agent chat
  it was started from (`cmux identify` reports it). current is that same
  object when cmux knows the caller, and the focused one otherwise (a shell
  outside cmux, or --socket/--session, where caller is refused).
";
