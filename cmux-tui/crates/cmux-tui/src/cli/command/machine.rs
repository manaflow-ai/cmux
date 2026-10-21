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
        ["list"] => {
            let params = catalog_params(flags);
            request(ResourceOperation::MachineList, selectors, flags, params)
        }
        [selector, "show"] => {
            selectors.insert("machine", "machine", selector)?;
            let params = catalog_params(flags);
            request(ResourceOperation::MachineGet, selectors, flags, params)
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

fn catalog_params(flags: &mut Flags) -> Map<String, Value> {
    if flags.boolean("catalog") { map_with("catalog", Value::Bool(true)) } else { Map::new() }
}
