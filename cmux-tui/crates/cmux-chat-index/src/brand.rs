//! The agent brand of a harness id (design/agent-icons/manifest.json), so
//! acpmux names it on each chat row and the app never resolves it per chat.
//! Matches `AgentBrandCatalog.brand(for:)` (CmuxAgentBrands) and `agentBrand`
//! (webviews): the same generated table and the same candidate order.

use crate::brand_generated::LOOKUP;

/// The brand for an agent, harness, alias, binary path or provider id, or
/// `None` when it has no mark. Matching ignores case and surrounding space,
/// then tries, in order: the whole id; the part after the last `:`; the last
/// path component; the first word; the first `-`, `_` or `.` separated part.
/// The first candidate the table knows decides, including ids known to have
/// no mark.
pub fn agent_brand(agent: &str) -> Option<&'static str> {
    candidates(agent).iter().find_map(|candidate| {
        LOOKUP
            .binary_search_by(|(key, _)| (*key).cmp(candidate.as_str()))
            .ok()
            .map(|index| LOOKUP[index].1)
    })?
}

fn candidates(raw: &str) -> Vec<String> {
    let id = raw.trim().to_lowercase();
    if id.is_empty() {
        return Vec::new();
    }
    let mut out = vec![id.clone()];
    fn add(out: &mut Vec<String>, value: Option<&str>) {
        if let Some(value) = value.filter(|v| !v.is_empty())
            && !out.iter().any(|known| known == value)
        {
            out.push(value.to_owned());
        }
    }
    add(&mut out, id.split(':').rfind(|part| !part.is_empty()));
    add(&mut out, id.split('/').rfind(|part| !part.is_empty()));
    let word = out.last().and_then(|last| last.split_whitespace().next()).map(str::to_owned);
    add(&mut out, word.as_deref());
    let part = word.as_deref().and_then(|w| w.split(['-', '_', '.']).find(|p| !p.is_empty()));
    add(&mut out, part);
    out
}
