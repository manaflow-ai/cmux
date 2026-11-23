//! Opt-in, offline capacity-pass experiment. No fleet/network/process authority.
use std::collections::HashSet;
use std::io::{self, Read};

const MAX_INPUT: u64 = 256 * 1024;
const MAX_HOSTS: usize = 256;
const REPORT_TTL: u64 = 30;
const TARGET_TTL: u64 = 60;

#[derive(Debug, Clone)]
struct Host {
    name: String,
    age: u64,
    ultra: bool,
    ceiling: u32,
    occupied: u32,
    cores: u32,
    cpu: f64,
    ram_gib: f64,
    used_gib: f64,
    memory_budget_gib: f64,
    yielding: bool,
}

impl Host {
    fn reason(&self) -> &'static str {
        if self.age > REPORT_TTL {
            "stale"
        } else if self.yielding {
            "yield"
        } else {
            "serving"
        }
    }

    fn headroom(&self, target: u32) -> Option<f64> {
        if self.reason() != "serving"
            || target > self.ceiling
            || f64::from(target) * 8.0 > self.memory_budget_gib
        {
            return None;
        }
        // Measured utilization already includes occupied clones. Project only additions.
        let added = f64::from(target.saturating_sub(self.occupied));
        let cpu = self.cpu + added * 400.0 / f64::from(self.cores);
        let ram = (self.used_gib + added * 8.0) * 100.0 / self.ram_gib;
        let room = (90.0 - cpu).min(90.0 - ram);
        (room > 0.0).then_some(room)
    }
}

fn parse(input: &str) -> Result<Vec<Host>, String> {
    let mut names = HashSet::new();
    let mut hosts = Vec::new();
    for (line, text) in input.lines().enumerate() {
        if text.trim().is_empty() || text.starts_with('#') {
            continue;
        }
        let fields: Vec<_> = text.split_whitespace().collect();
        let error = || {
            format!(
                "report line {}: expected 11 valid fields; see README.md",
                line + 1
            )
        };
        if fields.len() != 11 {
            return Err(error());
        }
        let number = |i: usize| fields[i].parse::<f64>().map_err(|_| error());
        let integer = |i: usize| fields[i].parse::<u32>().map_err(|_| error());
        let host = Host {
            name: fields[0].into(),
            age: fields[1].parse().map_err(|_| error())?,
            ultra: match fields[2] {
                "ultra" => true,
                "standard" => false,
                _ => return Err(error()),
            },
            ceiling: integer(3)?,
            occupied: integer(4)?,
            cores: integer(5)?,
            cpu: number(6)?,
            ram_gib: number(7)?,
            used_gib: number(8)?,
            memory_budget_gib: number(9)?,
            yielding: match fields[10] {
                "yes" => true,
                "no" => false,
                _ => return Err(error()),
            },
        };
        if host.name.len() > 128
            || !host
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            || !names.insert(host.name.clone())
            || hosts.len() >= MAX_HOSTS
            || host.ceiling > 64
            || host.occupied > 64
            || host.cores == 0
            || host.cores > 4096
            || !host.cpu.is_finite()
            || !(0.0..=100.0).contains(&host.cpu)
            || !host.ram_gib.is_finite()
            || host.ram_gib <= 0.0
            || host.ram_gib > 65536.0
            || !host.used_gib.is_finite()
            || !(0.0..=host.ram_gib).contains(&host.used_gib)
            || !host.memory_budget_gib.is_finite()
            || host.memory_budget_gib < 0.0
            || host.memory_budget_gib > (host.ram_gib * 0.9 - 8.0).max(0.0)
        {
            return Err(error());
        }
        hosts.push(host);
    }
    hosts.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(hosts)
}

fn plan(hosts: &[Host], queued: u64) -> Vec<u32> {
    // Occupied work is never killed, even if its target becomes zero on yield/staleness.
    let mut targets: Vec<_> = hosts
        .iter()
        .map(|h| {
            if h.reason() == "serving" {
                h.occupied
            } else {
                0
            }
        })
        .collect();
    if queued == 0 {
        for (host, target) in hosts.iter().zip(&mut targets) {
            if *target == 0 && host.headroom(1).is_some() {
                *target = 1;
            }
        }
        return targets;
    }
    // Each iteration consumes one of <= MAX_HOSTS * 64 slots, independent of queue size.
    let mut remaining = queued;
    while remaining > 0 {
        let best = hosts
            .iter()
            .enumerate()
            .filter_map(|(i, h)| h.headroom(targets[i] + 1).map(|room| (i, room, h.ultra)))
            .max_by(|a, b| a.1.total_cmp(&b.1).then(a.2.cmp(&b.2)).then(b.0.cmp(&a.0)));
        let Some((index, _, _)) = best else {
            break;
        };
        targets[index] += 1;
        remaining -= 1;
    }
    targets
}

fn run(args: &[String], input: &mut impl Read, output: &mut impl io::Write) -> Result<(), String> {
    if args.is_empty() {
        return writeln!(
            output,
            "disabled: opt in with --enabled --now UNIX_SECONDS --queued JOBS; reports on stdin"
        )
        .map_err(|e| e.to_string());
    }
    if args.len() != 5 || args[0] != "--enabled" || args[1] != "--now" || args[3] != "--queued" {
        return Err(
            "usage: capacity --enabled --now UNIX_SECONDS --queued JOBS < reports.tsv".into(),
        );
    }
    let now: u64 = args[2].parse().map_err(|_| "invalid timestamp")?;
    let expiry = now.checked_add(TARGET_TTL).ok_or("timestamp overflow")?;
    let queued: u64 = args[4].parse().map_err(|_| "invalid queued count")?;
    let mut text = String::new();
    input
        .take(MAX_INPUT + 1)
        .read_to_string(&mut text)
        .map_err(|e| e.to_string())?;
    if text.len() as u64 > MAX_INPUT {
        return Err("reports exceed 256 KiB".into());
    }
    let hosts = parse(&text)?;
    let targets = plan(&hosts, queued);
    let open: u64 = hosts
        .iter()
        .zip(&targets)
        .map(|(h, t)| u64::from(t.saturating_sub(h.occupied)))
        .sum();
    writeln!(
        output,
        "# advisory-only queued={queued} open={open} unmet={} expires_at={expiry}",
        queued.saturating_sub(open)
    )
    .map_err(|e| e.to_string())?;
    writeln!(output, "host\ttarget\toccupied\texpires_at\treason").map_err(|e| e.to_string())?;
    for (host, target) in hosts.iter().zip(targets) {
        writeln!(
            output,
            "{}\t{target}\t{}\t{expiry}\t{}",
            host.name,
            host.occupied,
            host.reason()
        )
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if let Err(error) = run(&args, &mut io::stdin(), &mut io::stdout()) {
        eprintln!("capacity: {error}");
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn hosts() -> Vec<Host> {
        parse("mini 0 standard 4 0 14 0 48 0 32 no\nultra 0 ultra 9 0 30 0 96 0 72 no").unwrap()
    }
    #[test]
    fn disabled_does_not_read_reports() {
        struct Unreadable;
        impl Read for Unreadable {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                panic!("read while disabled")
            }
        }
        let mut out = Vec::new();
        run(&[], &mut Unreadable, &mut out).unwrap();
        assert!(String::from_utf8(out).unwrap().starts_with("disabled:"));
    }
    #[test]
    fn queue_is_capped_by_projected_headroom() {
        assert_eq!(plan(&hosts(), u64::MAX), vec![3, 6]);
        assert_eq!(plan(&hosts(), 1), vec![0, 1]);
    }
    #[test]
    fn idle_means_one_warm_target_per_serving_host() {
        assert_eq!(plan(&hosts(), 0), vec![1, 1]);
    }
    #[test]
    fn yielding_and_stale_hosts_admit_nothing() {
        let mut h = hosts();
        h[0].yielding = true;
        h[0].occupied = 2;
        h[1].age = 31;
        assert_eq!(plan(&h, 10), vec![0, 0]);
        assert_eq!(h[0].occupied, 2);
        assert_eq!(plan(&h, 0), vec![0, 0]);
    }
    #[test]
    fn busy_clones_are_not_double_counted_or_killed() {
        let mut h = hosts();
        h[0].occupied = 3;
        h[0].cpu = 85.0;
        h[1].occupied = 8;
        h[1].cpu = 95.0;
        assert_eq!(plan(&h, 9), vec![3, 8]);
        assert_eq!(plan(&h, 0), vec![3, 8]);
    }
    #[test]
    fn ceiling_and_memory_budget_limit_admission() {
        let mut h = hosts();
        h[0].ceiling = 1;
        h[1].memory_budget_gib = 16.0;
        assert_eq!(plan(&h, 100), vec![1, 2]);
    }
    #[test]
    fn strict_ninety_percent_boundary() {
        let mut h = hosts();
        h[0].cpu = 90.0;
        h[1].used_gib = 86.4;
        assert_eq!(plan(&h, 1), vec![0, 0]);
    }
    #[test]
    fn duplicate_names_and_invalid_numbers_are_rejected() {
        for text in [
            "x 0 ultra 9 0 30 NaN 96 0 72 no",
            "x 0 ultra 9 0 30 0 96 0 96 no",
            "x 0 ultra 65 0 30 0 96 0 72 no",
            "x 0 ultra 9 0 0 0 96 0 72 no",
            "x 0 ultra 9 0 30 0 96 0 72 no\nx 0 ultra 9 0 30 0 96 0 72 no",
        ] {
            assert!(parse(text).is_err());
        }
    }
    #[test]
    fn ties_prefer_ultras_then_name_regardless_of_input_order() {
        let h = parse("z 0 ultra 4 0 14 0 48 0 32 no\na 0 standard 4 0 14 0 48 0 32 no").unwrap();
        assert_eq!(plan(&h, 1), vec![0, 1]);
    }
    #[test]
    fn stdin_to_expiring_targets() {
        let args = ["--enabled", "--now", "1000", "--queued", "2"].map(String::from);
        let mut input = "mini 0 standard 4 0 14 0 48 0 32 no".as_bytes();
        let mut out = Vec::new();
        run(&args, &mut input, &mut out).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("queued=2 open=2 unmet=0 expires_at=1060"));
        assert!(text.contains("mini\t2\t0\t1060\tserving"));
    }
}
