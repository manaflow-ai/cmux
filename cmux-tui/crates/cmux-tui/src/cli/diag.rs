//! Local diagnostics that need no session connection.

use std::io::{self, Write};

use cmux_tui_core::budgets::{self, Budget};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum DiagPlan {
    /// Print every named budget.
    Budgets,
}

pub(super) fn run(global: GlobalArgs, plan: DiagPlan) -> i32 {
    match plan {
        DiagPlan::Budgets => match global.output {
            OutputMode::Human => {
                let mut stdout = io::stdout().lock();
                let _ = stdout.write_all(budgets_text().as_bytes());
                let _ = stdout.flush();
                0
            }
            output => super::wire::print_local_success(&budgets_json(), output),
        },
    }
}

fn sorted_budgets() -> Vec<&'static Budget> {
    let mut rows: Vec<&Budget> = budgets::table().iter().collect();
    rows.sort_by(|left, right| left.name.cmp(right.name));
    rows
}

pub(super) fn budgets_json() -> Value {
    Value::Array(
        sorted_budgets()
            .into_iter()
            .map(|budget| {
                json!({
                    "name": budget.name,
                    "value": budget.value.amount(),
                    "unit": budget.value.unit(),
                    "stage": budget.stage,
                    "purpose": budget.purpose,
                    "site": budget.site,
                })
            })
            .collect(),
    )
}

pub(super) fn budgets_text() -> String {
    let rows = sorted_budgets();
    let name_width = rows.iter().map(|b| b.name.len()).max().unwrap_or(4).max(4);
    let stage_width = rows.iter().map(|b| b.stage.len()).max().unwrap_or(5).max(5);
    let mut out = format!(
        "{:<name_width$}  {:>10}  {:<stage_width$}  PURPOSE\n",
        "NAME", "VALUE", "STAGE"
    );
    for budget in rows {
        let value = format!("{} {}", budget.value.amount(), budget.value.unit());
        out.push_str(&format!(
            "{:<name_width$}  {:>10}  {:<stage_width$}  {}\n",
            budget.name, value, budget.stage, budget.purpose
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_round_trips_every_budget_in_name_order() {
        let value = budgets_json();
        let rows = value.as_array().expect("array");
        assert_eq!(rows.len(), budgets::table().len());
        let names: Vec<&str> = rows.iter().map(|row| row["name"].as_str().unwrap()).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        assert_eq!(names, sorted);
        for row in rows {
            let budget = budgets::find(row["name"].as_str().unwrap()).expect("known budget");
            assert_eq!(row["value"].as_u64().unwrap(), budget.value.amount());
            assert_eq!(row["unit"].as_str().unwrap(), budget.value.unit());
            assert_eq!(row["stage"].as_str().unwrap(), budget.stage);
            assert_eq!(row["site"].as_str().unwrap(), budget.site);
        }
    }

    #[test]
    fn text_table_lists_every_budget_once() {
        let text = budgets_text();
        assert!(text.starts_with("NAME"));
        for budget in budgets::table() {
            let rows = text
                .lines()
                .filter(|line| line.split_whitespace().next() == Some(budget.name))
                .count();
            assert_eq!(rows, 1, "{}", budget.name);
        }
        assert!(text.contains("16 ms"));
        assert!(text.contains("65536 bytes"));
    }
}
