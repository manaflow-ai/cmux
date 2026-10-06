//! `cmux screen --help`.

pub(super) const SCREEN_HELP: &str = "\
USAGE
  cmux screen list
  cmux screen create [--correlation-key <value>]
  cmux screen <selector> show|focus|close
  cmux screen <selector> rename --name <value>
  cmux screen <selector> pin|unpin
  cmux screen <selector> update [--pinned <bool>] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon]
  cmux screen <selector> move --index <n>
  cmux screen <selector> layout export
  cmux screen <selector> layout undo [--confirm-close]
    [--confirmation-token <value>]
  cmux screen <selector> column <split_…> update [--dock <bool>]
    [--edge left|right] [--mode docked|overlay] [--width <fraction>]
  cmux screen <selector> pane ...
  cmux screen group list [--workspace <selector>]
  cmux screen group create --screens <screen_…,...> [--name <value>] [--color <color>]
  cmux screen group <group> show|ungroup
  cmux screen group <group> update [--name <value>] [--color <color>] [--collapse|--expand]
  cmux screen group <group> add --screens <screen_…,...>
  cmux screen group remove --screens <screen_…,...>

Pinned screens sort first and leave their group. Group colors: grey, blue,
red, yellow, green, pink, purple, cyan, orange.

SELECTORS
  <selector> is an id (screen_…), current, or an exact name. Prefix name:
  to a name that looks like an id or a command word.
";
