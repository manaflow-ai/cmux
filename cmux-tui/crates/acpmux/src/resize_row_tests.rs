use super::*;
use crate::heavy_precheck::{Place, Shape, precheck};
use serde_json::{Value, json};

const DEFAULT: Size = Size::new(2, 4);

fn default_shape() -> Shape {
    Shape { vcpu: 2, mem_total: 4 * GIB, mem_available: Some(3 * GIB), disk_free: 20 * GB }
}

#[test]
fn the_rate_is_the_same_per_unit_at_every_size() {
    assert_eq!(DEFAULT.hourly_cents(), 15);
    assert_eq!(BURST.hourly_cents(), 118, "RFD 0133: about $1.18 an hour at 16 / 32");
    assert_eq!(Plan::Pro.ceiling().hourly_cents(), 82);
}

#[test]
fn the_first_button_resizes_inside_the_plan_and_upgrades_past_it() {
    assert_eq!(first_action(16, Plan::Max), First::Resize { to: BURST, hourly_cents: 118 });
    // Pro's ceiling holds the memory: resize to 8 / 32, not an upgrade.
    assert_eq!(
        first_action(16, Plan::Pro),
        First::Resize { to: Size::new(8, 32), hourly_cents: 82 }
    );
    // Plus stops at 16 GiB: "Upgrade to Pro for 8 vCPU / 32 GiB".
    assert_eq!(
        first_action(16, Plan::Plus),
        First::Upgrade { plan: Plan::Pro, to: Size::new(8, 32), hourly_cents: 82 }
    );
    assert_eq!(
        first_action(40, Plan::Pro),
        First::Upgrade { plan: Plan::Max, to: Size::new(32, 64), hourly_cents: 237 }
    );
    assert_eq!(first_action(40, Plan::Max), First::Resize { to: BIG_BURST, hourly_cents: 237 });
}

#[test]
fn chromium_on_the_default_vm_carries_the_rfd_numbers() {
    let w = precheck("fetch chromium", &default_shape(), &Place::default()).unwrap();
    let row = warning_row(&w, &default_shape(), DEFAULT, Plan::Max);
    let Why::Project { hours_here, hours_burst, burst_cents, disk_free_gb, memory_gb, .. } =
        &row.why
    else {
        panic!("{row:?}")
    };
    assert_eq!((*hours_here, *hours_burst), (Some(20.0), Some(1.5)));
    assert_eq!(*burst_cents, Some(296));
    assert_eq!((*disk_free_gb, *memory_gb), (20, 4));
    assert_eq!(row.first, First::Resize { to: BURST, hourly_cents: 118 });
    assert_eq!(row.back_to, DEFAULT);
}

#[test]
fn autosize_rows_say_what_happened() {
    let grew = autosize_row(Act::Grew, Reason::Memory, DEFAULT, BURST, BURST, Plan::Max);
    assert!(grew.undo_at_pause);
    assert_eq!(grew.hourly_cents, 118);
    assert_eq!(grew.upgrade, None);
    let held = autosize_row(
        Act::HeldAtPlanLimit,
        Reason::Memory,
        Size::new(4, 16),
        Size::new(4, 16),
        BURST,
        Plan::Plus,
    );
    assert_eq!(held.to, Size::new(4, 16));
    assert!(!held.undo_at_pause);
    assert_eq!(
        held.upgrade,
        Some(First::Upgrade { plan: Plan::Pro, to: Size::new(8, 32), hourly_cents: 82 })
    );
    let shrank = autosize_row(Act::Shrank, Reason::Idle, BURST, DEFAULT, DEFAULT, Plan::Max);
    assert_eq!((shrank.hourly_cents, shrank.undo_at_pause), (15, false));
}

/// The gallery's rows, as this module decides them: the pane's gallery reads
/// `webviews/src/agent-session/acpmux/conversation/resizeRow.fixtures.json`, so what it draws is
/// what Rust sends. `UPDATE_RESIZE_FIXTURES=1` rewrites the file.
fn gallery_rows() -> Value {
    let shape = default_shape();
    let chromium = precheck("fetch --nohooks chromium", &shape, &Place::default()).unwrap();
    let cargo = precheck(
        "cargo build --release",
        &shape,
        &Place { cwd: None, checkout_bytes: Some(40 * GIB) },
    )
    .unwrap();
    let llvm_shape = Shape { disk_free: 12 * GB, ..shape };
    let llvm = precheck("cmake -S llvm -B build -G Ninja", &llvm_shape, &Place::default()).unwrap();
    json!({
        "chromium": warning_row(&chromium, &shape, DEFAULT, Plan::Max),
        "chromiumOnPlus": warning_row(&chromium, &shape, DEFAULT, Plan::Plus),
        "llvm": warning_row(&llvm, &llvm_shape, DEFAULT, Plan::Pro),
        "bigCheckout": warning_row(&cargo, &shape, DEFAULT, Plan::Max),
        "pressure": pressure_row(3_800 * GIB / 1000, 4 * GIB, Some(6), DEFAULT, Plan::Max),
        "grew": autosize_row(Act::Grew, Reason::Memory, DEFAULT, BURST, BURST, Plan::Max),
        "grewCpu": autosize_row(Act::Grew, Reason::Cpu, DEFAULT, Size::new(8, 16), Size::new(8, 16), Plan::Max),
        "held": autosize_row(Act::HeldAtPlanLimit, Reason::Memory, Size::new(4, 16), Size::new(4, 16), BURST, Plan::Plus),
        "shrank": autosize_row(Act::Shrank, Reason::Idle, BURST, DEFAULT, DEFAULT, Plan::Max),
    })
}

#[test]
fn the_gallery_fixture_is_what_rust_sends() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../webviews/src/agent-session/acpmux/conversation/resizeRow.fixtures.json");
    let want = serde_json::to_string_pretty(&gallery_rows()).unwrap() + "\n";
    if std::env::var_os("UPDATE_RESIZE_FIXTURES").is_some() {
        std::fs::write(&path, &want).unwrap();
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(have, want, "run with UPDATE_RESIZE_FIXTURES=1 to rewrite {}", path.display());
}
