//! Rail selection after a catalog update removes the selected row.

use super::*;

fn rail_state(machines: &[u64], capabilities: MachineCapabilities) -> MachineUiState {
    MachineUiState::new(MachineSnapshot {
        machines: machines
            .iter()
            .map(|key| MachineDescriptor {
                key: MachineKey(*key),
                id: key.to_string(),
                name: key.to_string(),
                subtitle: String::new(),
                status: MachineStatus::Running,
                platform: None,
                capabilities: Vec::new(),
            })
            .collect(),
        active: None,
        capabilities,
    })
}

#[test]
fn deleting_every_machine_lands_on_the_first_action_row() {
    let both = MachineCapabilities { create: true, connect: true };
    let mut previous = rail_state(&[1], both);
    previous.select_rail_target(MachineRailTarget::Machine(MachineKey(1)));
    let mut update = rail_state(&[], both);

    update.reconcile_navigation_from(&previous);

    assert_eq!(update.rail_target(), Some(MachineRailTarget::NewVm));
}

#[test]
fn a_vanished_action_row_clamps_to_the_last_remaining_row() {
    let mut previous = rail_state(&[], MachineCapabilities { create: true, connect: true });
    previous.select_rail_target(MachineRailTarget::ConnectMachine);
    let mut update = rail_state(&[], MachineCapabilities { create: true, connect: false });

    update.reconcile_navigation_from(&previous);

    assert_eq!(update.rail_target(), Some(MachineRailTarget::NewVm));
}

#[test]
fn a_rail_with_no_rows_resets_the_selection() {
    let mut previous = rail_state(&[1], MachineCapabilities::default());
    previous.select_rail_target(MachineRailTarget::Machine(MachineKey(1)));
    let mut update = rail_state(&[], MachineCapabilities::default());

    update.reconcile_navigation_from(&previous);

    assert_eq!(update.selection, 0);
    assert_eq!(update.rail_target(), None);
}
