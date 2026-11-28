// Keep the Swift package's header-only ABI in sync with the release export contract.
#[test]
fn swift_screen_kit_header_matches_canonical_contract() {
    let canonical = include_str!("../include/cmux_screen_kit.h");
    let swift = include_str!(
        "../../../../Packages/Shared/CmuxScreenKit/Sources/CCmuxScreenKit/include/cmux_screen_kit.h"
    );
    // The introductory comments describe each consumer; all declarations must match.
    let contract = |header: &'static str| header.split_once("#ifndef CMUX_SCREEN_KIT_H").unwrap().1;
    assert_eq!(contract(canonical), contract(swift));
}
