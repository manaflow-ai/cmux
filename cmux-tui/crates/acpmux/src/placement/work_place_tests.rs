//! One scenario per RFD 0072 S1-S11 (Leo's AutoCloud scenarios, 2026-11-25), plus the off switch
//! and algorithm 2's arithmetic.

use super::*;

const SMALL: Shape = Shape { vcpu: 1.0, mem_gib: 1.0 };
const CODE_VM: Shape = Shape { vcpu: 2.0, mem_gib: 4.0 };

fn idle_mac() -> Host {
    Host {
        ncpu: 12.0,
        load1: 1.0,
        psi_cpu_some10: None,
        mem_available_gib: 24.0,
        sleeping: false,
        on_battery: false,
        battery_percent: None,
        person_cpu_share: 0.0,
        person_heavy: false,
    }
}

fn no_machines() -> Machines {
    Machines { work_vm: None, pinned: None }
}

fn paused_vm() -> Machines {
    Machines { work_vm: Some(WorkVm { shape: CODE_VM, paused: true }), pinned: None }
}

fn work(class: Class, local_s: f64, need: Shape) -> Work {
    Work { class, local_s: Some(local_s), need: Some(need), cpu_s: None, listens: false }
}

fn ls() -> Work {
    work(Class::Other, 0.2, SMALL)
}

fn cargo_build() -> Work {
    work(Class::Rust, 600.0, Shape { vcpu: 8.0, mem_gib: 8.0 })
}

fn chromium() -> Work {
    Work {
        class: Class::Other,
        local_s: Some(4.0 * 3_600.0),
        need: Some(Shape { vcpu: 32.0, mem_gib: 64.0 }),
        cpu_s: Some(200.0 * 3_600.0),
        listens: false,
    }
}

fn place(w: &Work, h: &Host, m: &Machines) -> Verdict {
    decide(w, h, m, &Policy::default())
}

#[test]
fn off_by_default() {
    // Reads only: the switch is unset unless a caller set it.
    if std::env::var(ENV).is_err() {
        assert!(!enabled());
    }
}

#[test]
fn s1_omni_folder_reads_stay_local_and_need_no_machine() {
    // Listing a huge folder is a manifest read: it fits here and starts no machine.
    let v = place(&ls(), &idle_mac(), &no_machines());
    assert_eq!(v.place, Place::Local);
    assert_eq!(v.reason, Reason::Fits);
}

#[test]
fn s2_work_follows_the_chat_to_its_vm_and_its_working_folders() {
    let m = Machines { work_vm: Some(WorkVm { shape: CODE_VM, paused: false }), pinned: None };
    let v = place(&ls(), &idle_mac(), &m);
    assert_eq!(v.place, Place::WorkVm { resume: false });
    assert_eq!(v.reason, Reason::OnVm);
}

#[test]
fn s3_first_cloud_command_resumes_the_warm_paused_vm() {
    // A busy Mac sends a mid-size test off; the paused work VM resumes for it.
    let mut h = idle_mac();
    h.load1 = 30.0;
    let w = work(Class::Other, 120.0, Shape { vcpu: 2.0, mem_gib: 2.0 });
    let v = place(&w, &h, &paused_vm());
    assert_eq!(v.place, Place::WorkVm { resume: true });
    assert_eq!(v.reason, Reason::Stretch);
    assert!(v.lose_s.unwrap() > v.remote_s.unwrap());
}

#[test]
fn s4_growing_work_grows_the_vm_in_place_then_leaves_past_the_cap() {
    let mut h = idle_mac();
    h.load1 = 30.0;
    let v = place(&cargo_build(), &h, &paused_vm());
    assert_eq!(v.reason, Reason::Stretch);
    let Place::Grow { to } = v.place else { panic!("{v:?}") };
    assert!(to.vcpu >= 8.0 && to.vcpu <= GROW_CEILING.vcpu, "{to:?}");
    assert!(to.mem_gib >= CODE_VM.mem_gib, "never shrinks: {to:?}");

    // Past the 8 vCPU / 16 GiB cap a Rust build goes to the pool, not a bigger move.
    let big = work(Class::Rust, 1_800.0, Shape { vcpu: 16.0, mem_gib: 24.0 });
    assert_eq!(place(&big, &h, &paused_vm()).place, Place::Pool);
}

#[test]
fn s5_a_build_stays_local_while_the_mac_has_room() {
    // AutoCloud moves per command: an idle Mac keeps a build whose stretch costs less than the
    // pool's queue (algorithm 2).
    let v = place(&cargo_build(), &idle_mac(), &no_machines());
    assert_eq!(v.place, Place::Local);
    // Loaded past the pool's 246 s + 20 s, the same build leaves.
    let mut h = idle_mac();
    h.load1 = 24.0;
    let v = place(&cargo_build(), &h, &no_machines());
    assert_ne!(v.place, Place::Local);
    assert_eq!(v.reason, Reason::Stretch);
}

#[test]
fn s6_done_work_does_not_pin_the_next_small_command_to_a_new_machine() {
    // With no work VM (paused and gone) a small command runs here: nothing starts for it.
    let v = place(&ls(), &idle_mac(), &no_machines());
    assert_eq!(v.place, Place::Local);
}

#[test]
fn s7_lid_close_sends_work_to_the_cloud() {
    let mut h = idle_mac();
    h.sleeping = true;
    let v = place(&ls(), &h, &paused_vm());
    assert_eq!(v.place, Place::WorkVm { resume: true });
    assert_eq!(v.reason, Reason::Sleep);
    // With no VM yet one is made, never left on a sleeping Mac.
    let v = place(&ls(), &h, &no_machines());
    assert!(matches!(v.place, Place::BiggerVm { .. }), "{v:?}");
}

#[test]
fn s8_photoshop_routes_new_agent_work_off_the_mac() {
    let mut h = idle_mac();
    h.person_heavy = true;
    h.person_cpu_share = 0.7;
    let v = place(&cargo_build(), &h, &paused_vm());
    assert_eq!(v.reason, Reason::PersonBusy);
    assert_ne!(v.place, Place::Local);
    // The person's share shrinks the agents' budget: the same load stretches more.
    let mut busy = idle_mac();
    busy.person_cpu_share = 0.7;
    assert!(stretch(&busy, 8.0) > stretch(&idle_mac(), 8.0));
}

#[test]
fn s9_agents_dev_server_runs_on_a_serve_vm_beside_the_persons_build() {
    let mut h = idle_mac();
    h.person_heavy = true; // the person's own web build
    let mut w = ls();
    w.listens = true;
    let v = place(&w, &h, &no_machines());
    assert_eq!(v.place, Place::ServeVm);
    assert_eq!(v.reason, Reason::Listens);
}

#[test]
fn s10_chromium_never_runs_on_the_mac_and_shows_an_estimate() {
    let v = place(&chromium(), &idle_mac(), &no_machines());
    assert_eq!(v.reason, Reason::Huge);
    let Place::BiggerVm { shape } = v.place else { panic!("{v:?}") };
    assert!(shape.vcpu >= 32.0 && shape.vcpu <= MAX_WORKLOAD_VCPU);
    let dollars = v.estimate_card.expect("above the team threshold a card shows first");
    assert!(dollars > Policy::default().estimate_card_dollars);
    // A cheap huge job (under the threshold) shows no card.
    let rich = Policy { estimate_card_dollars: 1_000.0, ..Policy::default() };
    assert_eq!(decide(&chromium(), &idle_mac(), &no_machines(), &rich).estimate_card, None);
}

#[test]
fn s11_a_machine_got_by_hand_is_never_moved() {
    let mut h = idle_mac();
    h.sleeping = true;
    h.person_heavy = true;
    let m = Machines { work_vm: None, pinned: Some(Pinned::Local) };
    let v = place(&chromium(), &h, &m);
    assert_eq!((v.place, v.reason), (Place::Local, Reason::Pinned));
    let m = Machines {
        work_vm: Some(WorkVm { shape: CODE_VM, paused: false }),
        pinned: Some(Pinned::Vm(CODE_VM)),
    };
    let v = place(&cargo_build(), &idle_mac(), &m);
    assert_eq!((v.place, v.reason), (Place::WorkVm { resume: false }, Reason::Pinned));
}

#[test]
fn low_battery_and_short_memory_leave_the_mac() {
    let mut h = idle_mac();
    h.on_battery = true;
    h.battery_percent = Some(10);
    assert_eq!(place(&ls(), &h, &paused_vm()).reason, Reason::LowBattery);
    let mut h = idle_mac();
    h.mem_available_gib = 6.0;
    let w = work(Class::Other, 30.0, Shape { vcpu: 2.0, mem_gib: 4.0 });
    assert_eq!(place(&w, &h, &paused_vm()).reason, Reason::MemoryShort);
}

#[test]
fn stretch_reads_psi_where_load_says_nothing() {
    let mut h = idle_mac();
    h.psi_cpu_some10 = Some(50.0);
    assert!((stretch(&h, 1.0) - 2.0).abs() < 1e-9);
    assert!((stall_dollars(360.0) - 1.0).abs() < 1e-9);
}
