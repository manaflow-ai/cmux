//! An agent question's selections as an answer (`AgentDialogDesk.answer`, `target`): each
//! selection names an item (`ITEM=CHOICE`, or the only item) and one of its options by id or
//! label, exact first, then ignoring case; other text is the item's Other text where it takes it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::{swift_split, trim_whitespace};

/// One option of a question item.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct Option_ {
    pub id: String,
    pub label: String,
}

/// One item of an agent question (`AgentQuestion.Item`).
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub options: Vec<Option_>,
    #[serde(default)]
    pub allows_other: bool,
}

/// One item's answer (`AgentQuestionAnswer.Selection`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub option_ids: Vec<String>,
    pub other: Option<String>,
}

/// Why the selections do not answer the question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "error", rename_all = "camelCase")]
pub enum Failure {
    /// The question has several items and a selection named none of them.
    NameTheItem,
    /// `value` is not an option of the item (`item` is its header or prompt) and it takes no Other.
    UnknownOption { value: String, item: String, choices: String },
}

fn same_ignoring_case(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

/// The answer, by item id.
pub fn answer(
    selections: &[String],
    items: &[Item],
) -> Result<BTreeMap<String, Selection>, Failure> {
    let mut chosen: BTreeMap<String, Selection> = BTreeMap::new();
    for selection in selections {
        let (item, value) = target(selection, items)?;
        let mut current = chosen.get(&item.id).cloned().unwrap_or_default();
        let matched =
            item.options.iter().find(|o| o.id == value || o.label == value).or_else(|| {
                item.options.iter().find(|o| {
                    same_ignoring_case(&o.id, &value) || same_ignoring_case(&o.label, &value)
                })
            });
        if let Some(option) = matched {
            if !current.option_ids.contains(&option.id) {
                current.option_ids.push(option.id.clone());
            }
        } else if item.allows_other {
            current.other = Some(match current.other {
                Some(other) => format!("{other}, {value}"),
                None => value,
            });
        } else {
            return Err(Failure::UnknownOption {
                value,
                item: item.header.clone().unwrap_or_else(|| item.prompt.clone()),
                choices: item
                    .options
                    .iter()
                    .map(|o| o.label.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
            });
        }
        chosen.insert(item.id.clone(), current);
    }
    Ok(chosen)
}

/// The item a selection names and its choice: the text before an `=` (any of them, in order)
/// names an item by id, prompt or header, exact first, then trimmed and ignoring case; else the
/// question's only item takes the whole selection.
fn target<'a>(selection: &str, items: &'a [Item]) -> Result<(&'a Item, String), Failure> {
    for (split, _) in selection.match_indices('=') {
        let key = trim_whitespace(&selection[..split]);
        let names = |item: &'a Item| {
            [item.id.as_str(), item.prompt.as_str(), item.header.as_deref().unwrap_or("")]
        };
        let found = items.iter().find(|item| names(item).contains(&key)).or_else(|| {
            items.iter().find(|item| {
                names(item)
                    .iter()
                    .any(|name| !name.is_empty() && same_ignoring_case(trim_whitespace(name), key))
            })
        });
        if let Some(item) = found {
            return Ok((item, trim_whitespace(&selection[split + 1..]).to_owned()));
        }
    }
    match items {
        [only] => Ok((only, trim_whitespace(selection).to_owned())),
        _ => Err(Failure::NameTheItem),
    }
}

/// The choice an app ask takes from `selections`: one selection's text after its first `=` (or
/// the whole of it), else nothing.
pub fn app_ask_choice(selections: &[String]) -> String {
    match selections {
        [one] => swift_split(one, '=', 1).last().map(|s| (*s).to_owned()).unwrap_or_default(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opt(id: &str, label: &str) -> Option_ {
        Option_ { id: id.into(), label: label.into() }
    }

    fn color() -> Item {
        Item {
            id: "q1".into(),
            prompt: "Which color?".into(),
            header: Some("Color".into()),
            options: vec![opt("r", "Red"), opt("g", "Green")],
            allows_other: false,
        }
    }

    fn size() -> Item {
        Item {
            id: "q2".into(),
            prompt: "Which size?".into(),
            header: None,
            options: vec![opt("s", "Small"), opt("l", "Large")],
            allows_other: true,
        }
    }

    fn sel(values: &[&str]) -> Vec<String> {
        values.iter().map(|s| (*s).to_owned()).collect()
    }

    fn picked(ids: &[&str], other: Option<&str>) -> Selection {
        Selection {
            option_ids: ids.iter().map(|s| (*s).to_owned()).collect(),
            other: other.map(str::to_owned),
        }
    }

    #[test]
    fn one_item_takes_a_bare_choice_by_label_or_id_any_case() {
        let items = [color()];
        let got = answer(&sel(&["Red", "g", "red"]), &items).unwrap();
        assert_eq!(got["q1"], picked(&["r", "g"], None));
        let got = answer(&sel(&[" GREEN "]), &items).unwrap();
        assert_eq!(got["q1"], picked(&["g"], None));
    }

    #[test]
    fn items_named_by_id_prompt_or_header() {
        let items = [color(), size()];
        let got = answer(&sel(&["q1=Red", "Which size? = large", "color=g"]), &items).unwrap();
        assert_eq!(got["q1"], picked(&["r", "g"], None));
        assert_eq!(got["q2"], picked(&["l"], None));
    }

    #[test]
    fn several_items_need_a_name() {
        let items = [color(), size()];
        assert_eq!(answer(&sel(&["Red"]), &items), Err(Failure::NameTheItem));
        assert_eq!(answer(&sel(&["nope=Red"]), &items), Err(Failure::NameTheItem));
    }

    #[test]
    fn a_later_equals_sign_can_name_the_item() {
        // "a=b" names no item at "a", but "a=b" is not an item either; the only item takes it whole.
        let items = [size()];
        let got = answer(&sel(&["x=y"]), &items).unwrap();
        assert_eq!(got["q2"], picked(&[], Some("x=y")));
        let mut odd = size();
        odd.id = "a=b".into();
        let got = answer(&sel(&["a=b=Small"]), &[odd, color()]).unwrap();
        assert_eq!(got["a=b"], picked(&["s"], None));
    }

    #[test]
    fn an_empty_key_names_an_item_without_a_header() {
        let items = [color(), size()];
        let got = answer(&sel(&["=Small"]), &items).unwrap();
        assert_eq!(got["q2"], picked(&["s"], None));
    }

    #[test]
    fn other_text_joins_and_unknown_options_fail() {
        let items = [color(), size()];
        let got = answer(&sel(&["q2=Huge", "q2=Tiny", "q2=s"]), &items).unwrap();
        assert_eq!(got["q2"], picked(&["s"], Some("Huge, Tiny")));
        assert_eq!(
            answer(&sel(&["q1=Blue"]), &items),
            Err(Failure::UnknownOption {
                value: "Blue".into(),
                item: "Color".into(),
                choices: "Red, Green".into()
            })
        );
        let mut no_header = color();
        no_header.header = None;
        assert_eq!(
            answer(&sel(&["Blue"]), &[no_header]),
            Err(Failure::UnknownOption {
                value: "Blue".into(),
                item: "Which color?".into(),
                choices: "Red, Green".into()
            })
        );
    }

    #[test]
    fn app_ask_choice_is_after_the_first_equals() {
        assert_eq!(app_ask_choice(&sel(&["allow"])), "allow");
        assert_eq!(app_ask_choice(&sel(&["mode=allow"])), "allow");
        assert_eq!(app_ask_choice(&sel(&["mode=a=b"])), "a=b");
        assert_eq!(app_ask_choice(&sel(&["mode="])), "mode");
        assert_eq!(app_ask_choice(&sel(&["a", "b"])), "");
        assert_eq!(app_ask_choice(&sel(&[""])), "");
    }
}
