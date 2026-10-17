use super::*;

pub(super) fn parse(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
    surface: crate::cli::Surface,
) -> Result<CommandPlan, UsageError> {
    if surface == crate::cli::Surface::Cmux && words.get(1).map(String::as_str) == Some("session") {
        return Err(crate::cli::not_in_cmux("session"));
    }
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::MachineList, selectors, flags, Map::new()),
        [selector, "show"] => {
            selectors.insert("machine", "machine", selector)?;
            request(ResourceOperation::MachineGet, selectors, flags, Map::new())
        }
        [machine, "session", "list"] => {
            selectors.insert("machine", "machine", machine)?;
            request(ResourceOperation::SessionList, selectors, flags, Map::new())
        }
        [machine, "session", session, "open"] => {
            selectors.insert("machine", "machine", machine)?;
            selectors.insert("session", "session", session)?;
            request(ResourceOperation::SessionOpen, selectors, flags, Map::new())
        }
        _ => usage("machine action"),
    }
}
