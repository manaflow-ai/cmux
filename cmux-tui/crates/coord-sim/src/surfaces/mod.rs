//! The load on the app surfaces besides acpmux itself (Leo, 2026-11-19, paraphrased: stress test everything):
//!
//!   coord-sim surface --target app-host --out DIR [plan flags]
//!       writes the records the NEXT desktop pane bench serves (records.rs `write`); the bench is
//!       webviews/bench/coord-sim-load.bench.ts, which runs it itself (COORD_SIM_BIN) and drives the real pane.
//!       (cmux-app-host itself is the QuickJS app VM and carries no chat; the pane is what a reader uses.)
//!   coord-sim surface --target relay --relay-bin PATH --out RUN_DIR [--storms K --storm-every S] [plan flags]
//!       N coordinators through a real cmux-relay (relay.rs).
//!   coord-sim surface --target ios --out DIR [plan flags]
//!       the same records as one chat's replay fixture for the iOS list rig (ios.rs).
//!
//! Plan flags (records.rs `Plan`): --coordinators N (3) --rate X (10) --seconds S (30) --history N (5000)
//! --seed N (1) --max-event-bytes B (262144) --max-gap-ms MS (5000) --shape FILE (built-in shape).

pub mod ios;
pub mod records;
pub mod relay;
pub mod ws;

use crate::shape::Shape;

/// The entry `drive --target app-host|relay|ios` can call with the same flags.
pub fn drive(target: &str, args: &[String]) -> Result<(), String> {
    match target {
        "relay" => relay::run(args),
        "app-host" | "desktop" => {
            let shape = Shape::load(crate::flag(args, "--shape"))?;
            let plan = records::Plan::from_args(args)?;
            let out = crate::flag(args, "--out").ok_or("--out DIR")?;
            records::write(&shape, &plan, out)?;
            println!("{out}");
            Ok(())
        }
        "ios" => ios::run(args),
        other => Err(format!("--target {other:?}: app-host, relay or ios")),
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    let target = crate::flag(args, "--target").ok_or("--target app-host|relay|ios")?;
    drive(target, args)
}
