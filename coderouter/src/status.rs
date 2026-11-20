use std::env;
use std::io::{self, IsTerminal};

use serde_json::Value;

const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[2m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const CYAN: &str = "\x1b[36m";
const ALT_ROW: &str = "\x1b[48;5;236m";
const MIN_NEW_SESSION_HEADROOM: f64 = 40.0;

#[derive(Clone)]
struct Cell {
    text: String,
    style: &'static str,
}

#[derive(Clone)]
struct Column {
    key: &'static str,
    title: &'static str,
    width: usize,
}

#[derive(Clone, Copy)]
struct Window {
    used: f64,
    seconds: u64,
    reset: u64,
}

pub fn render(value: &Value, team_name: &str, team_id: &str) {
    let colored = color_enabled();
    println!("Credential storage: coderouter cloud ({team_name}, {team_id})");
    let usage_age = value.get("usageAgeSeconds").and_then(Value::as_u64);
    let cache_max = value.get("cacheMaxAgeSeconds").and_then(Value::as_u64);
    if let Some(age) = usage_age.filter(|age| *age > 0) {
        println!(
            "{}",
            styled(
                colored,
                DIM,
                &format!(
                    "Usage cached {age}s ago{}",
                    cache_max
                        .map(|max| format!(" ({max}s refresh target)"))
                        .unwrap_or_default()
                ),
            )
        );
    }
    let accounts = value
        .get("accounts")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if accounts.is_empty() {
        println!("\nNo accounts configured. Run `coderouter add`.");
        return;
    }

    let mut providers = Vec::<&str>::new();
    for account in accounts {
        let provider = text(account, "provider").unwrap_or("unknown");
        if !providers.contains(&provider) {
            providers.push(provider);
        }
    }
    println!();
    let mut row_index = 0;
    for (group_index, provider) in providers.into_iter().enumerate() {
        if group_index > 0 {
            println!();
        }
        let columns = columns(provider, terminal_width());
        let title = match provider {
            "codex" => "Codex accounts",
            "opencode" | "opencode-go" => "OpenCode Go accounts",
            other => other,
        };
        print_line(
            &columns,
            |_| Cell::new("", ""),
            colored,
            "",
            Some((title, BOLD_DIM)),
        );
        print_line(
            &columns,
            |column| Cell::new(column.title, DIM),
            colored,
            "",
            None,
        );
        print_line(
            &columns,
            |column| Cell::new("─".repeat(column.width), DIM),
            colored,
            "",
            None,
        );
        for account in accounts
            .iter()
            .filter(|account| text(account, "provider").unwrap_or("unknown") == provider)
        {
            let cells = account_cells(account, row_index + 1);
            let row_style = if row_index % 2 == 1 { ALT_ROW } else { "" };
            print_line(
                &columns,
                |column| cells(column.key),
                colored,
                row_style,
                None,
            );
            row_index += 1;
        }
    }
    println!();
}

const BOLD_DIM: &str = "\x1b[1m\x1b[2m";

impl Cell {
    fn new(text: impl Into<String>, style: &'static str) -> Self {
        Self {
            text: text.into(),
            style,
        }
    }
}

fn columns(provider: &str, width: usize) -> Vec<Column> {
    let mut columns = vec![
        Column::new("#", "#", 3),
        Column::new("account", "Account", if width < 100 { 20 } else { 36 }),
        Column::new("plan", "Plan", if width < 100 { 4 } else { 6 }),
        Column::new("state", "State", 14),
        Column::new("use", "Use", if width < 100 { 16 } else { 34 }),
    ];
    if provider == "codex" {
        for column in [
            Column::new("5h", "5h", 9),
            Column::new("7d", "7d", 12),
            Column::new("reset", "1x reset", 8),
            Column::new("credits", "$", 7),
            Column::new("spark", "Spark", 8),
            Column::new("spark-weekly", "Spark wk", 10),
        ] {
            if grid_width(&columns) + 2 + column.width <= width {
                columns.push(column);
            }
        }
    }
    columns
}

impl Column {
    fn new(key: &'static str, title: &'static str, width: usize) -> Self {
        Self { key, title, width }
    }
}

fn account_cells(account: &Value, index: usize) -> impl Fn(&str) -> Cell {
    let usage = account.get("usage").unwrap_or(&Value::Null);
    let general = usage.get("rate_limit").unwrap_or(&Value::Null);
    let short = quota_window(general, "primary_window")
        .filter(|window| window.seconds > 0 && window.seconds <= 6 * 60 * 60)
        .or_else(|| {
            quota_window(general, "secondary_window")
                .filter(|window| window.seconds > 0 && window.seconds <= 6 * 60 * 60)
        });
    let long = quota_window(general, "primary_window")
        .filter(|window| window.seconds > 6 * 60 * 60)
        .or_else(|| {
            quota_window(general, "secondary_window").filter(|window| window.seconds > 6 * 60 * 60)
        });
    let (spark_short, spark_long) = spark_windows(usage);
    let cooked = long.is_some_and(|window| window.used >= 100.0);
    let temp_cooked = !cooked && short.is_some_and(|window| window.used >= 100.0);
    let api_state = text(account, "state").unwrap_or("unknown");
    let broken = matches!(api_state, "broken" | "expired");
    let headroom = [short, long]
        .into_iter()
        .flatten()
        .map(|window| (100.0 - window.used).max(0.0))
        .reduce(f64::min)
        .unwrap_or(100.0);
    let state = if broken {
        format!("{api_state}, error")
    } else if cooked {
        format!("{api_state}, cooked")
    } else if temp_cooked {
        format!("{api_state}, temp")
    } else {
        api_state.to_owned()
    };
    let state_color = if broken || cooked {
        RED
    } else if temp_cooked {
        YELLOW
    } else if api_state == "active" {
        CYAN
    } else {
        ""
    };
    let pick = if broken {
        "usage unavailable".to_owned()
    } else if cooked {
        "cooked, cannot switch".to_owned()
    } else if temp_cooked {
        "temp cooked, cannot start".to_owned()
    } else if headroom < MIN_NEW_SESSION_HEADROOM {
        format!(
            "{headroom:.0}% left, protected < {:.0}%",
            MIN_NEW_SESSION_HEADROOM
        )
    } else if let Some(window) = short.filter(|window| window.reset > 0) {
        format!("{headroom:.0}% left, 5h reset {}", duration(window.reset))
    } else {
        format!("{headroom:.0}% left")
    };
    let pick_color = if broken || cooked {
        RED
    } else if temp_cooked || headroom < MIN_NEW_SESSION_HEADROOM {
        YELLOW
    } else {
        GREEN
    };
    let reset_count = usage
        .pointer("/rate_limit_reset_credits/available_count")
        .and_then(Value::as_i64);
    let reset = match reset_count {
        Some(value) if value > 0 => Cell::new("avail", GREEN),
        Some(_) => Cell::new("used", YELLOW),
        None => Cell::new("unknown", DIM),
    };
    let balance = usage
        .pointer("/credits/balance")
        .and_then(Value::as_str)
        .map(|value| format!("${value}"))
        .unwrap_or_default();
    let label = text(account, "label").unwrap_or("unknown").to_owned();
    let plan = text(usage, "plan_type").unwrap_or("").to_owned();

    move |key| match key {
        "#" => Cell::new(index.to_string(), DIM),
        "account" => Cell::new(label.clone(), BOLD_WHITE),
        "plan" => Cell::new(plan.clone(), DIM),
        "state" => Cell::new(state.clone(), state_color),
        "use" => Cell::new(pick.clone(), pick_color),
        "5h" => {
            if cooked {
                Cell::new("", "")
            } else {
                window_cell(short)
            }
        }
        "7d" => window_cell(long),
        "reset" => reset.clone(),
        "credits" => Cell::new(balance.clone(), ""),
        "spark" => {
            if spark_long.is_some_and(|window| window.used >= 100.0) {
                Cell::new("", "")
            } else {
                window_cell(spark_short)
            }
        }
        "spark-weekly" => window_cell(spark_long),
        _ => Cell::new("", ""),
    }
}

const BOLD_WHITE: &str = "\x1b[1m\x1b[37m";

fn quota_window(rate_limit: &Value, key: &str) -> Option<Window> {
    let value = rate_limit.get(key)?;
    Some(Window {
        used: value.get("used_percent")?.as_f64()?,
        seconds: value
            .get("limit_window_seconds")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        reset: value
            .get("reset_after_seconds")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    })
}

fn spark_windows(usage: &Value) -> (Option<Window>, Option<Window>) {
    let Some(limits) = usage
        .get("additional_rate_limits")
        .and_then(Value::as_array)
    else {
        return (None, None);
    };
    for limit in limits {
        let name = text(limit, "limit_name").unwrap_or("").to_ascii_lowercase();
        if name.contains("spark") {
            let rate = limit.get("rate_limit").unwrap_or(&Value::Null);
            return (
                quota_window(rate, "primary_window"),
                quota_window(rate, "secondary_window"),
            );
        }
    }
    (None, None)
}

fn window_cell(window: Option<Window>) -> Cell {
    let Some(window) = window else {
        return Cell::new("", "");
    };
    let left = (100.0 - window.used).max(0.0);
    let text = if window.reset > 0 {
        format!("{left:.0}%/{}", duration(window.reset))
    } else {
        format!("{left:.0}%")
    };
    let color = if window.used >= 90.0 {
        RED
    } else if window.used >= 70.0 {
        YELLOW
    } else {
        GREEN
    };
    Cell::new(text, color)
}

fn duration(seconds: u64) -> String {
    if seconds >= 86_400 {
        let days = seconds / 86_400;
        let hours = (seconds % 86_400) / 3_600;
        if hours > 0 {
            format!("{days}d{hours}h")
        } else {
            format!("{days}d")
        }
    } else if seconds >= 3_600 {
        let hours = seconds / 3_600;
        let minutes = (seconds % 3_600) / 60;
        if minutes > 0 {
            format!("{hours}h{minutes}m")
        } else {
            format!("{hours}h")
        }
    } else {
        format!("{}m", (seconds.max(60) + 30) / 60)
    }
}

fn print_line(
    columns: &[Column],
    cell: impl Fn(&Column) -> Cell,
    colored: bool,
    row_style: &'static str,
    group: Option<(&str, &'static str)>,
) {
    if let Some((label, group_style)) = group {
        println!(
            "{}",
            styled(colored, group_style, &fit(label, grid_width(columns)))
        );
        return;
    }
    for (index, column) in columns.iter().enumerate() {
        if index > 0 {
            print!("{}", styled(colored, row_style, "  "));
        }
        let cell = cell(column);
        let style = if row_style.is_empty() {
            cell.style.to_owned()
        } else {
            format!("{row_style}{}", cell.style)
        };
        print!(
            "{}",
            styled(colored, &style, &fit(&cell.text, column.width))
        );
    }
    println!();
}

fn fit(value: &str, width: usize) -> String {
    let count = value.chars().count();
    if count <= width {
        return format!("{value:<width$}");
    }
    if width <= 1 {
        return "…".repeat(width);
    }
    let mut result: String = value.chars().take(width - 1).collect();
    result.push('…');
    result
}

fn grid_width(columns: &[Column]) -> usize {
    columns.iter().map(|column| column.width).sum::<usize>() + columns.len().saturating_sub(1) * 2
}

fn styled(enabled: bool, code: &str, value: &str) -> String {
    if enabled && !code.is_empty() && !value.is_empty() {
        format!("{code}{value}{RESET}")
    } else {
        value.to_owned()
    }
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn terminal_width() -> usize {
    env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse().ok())
        .or_else(|| {
            crossterm::terminal::size()
                .ok()
                .map(|(width, _)| width as usize)
        })
        .unwrap_or(140)
}

fn color_enabled() -> bool {
    if env::var_os("NO_COLOR").is_some()
        || env::var_os("CR_NO_COLOR").is_some()
        || env::var("TERM").is_ok_and(|value| value == "dumb")
    {
        return false;
    }
    if env::var("FORCE_COLOR").is_ok_and(|value| value != "0") {
        return true;
    }
    io::stdout().is_terminal()
}
