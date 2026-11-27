use super::*;

#[test]
fn check_program_says_what_this_build_did() {
    let ok = b"fn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";
    let bad =
        b"var<private> n: f32;\nfn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";
    if CHECKS_PROGRAMS {
        assert_eq!(check_program(ok), ProgramCheck::Passed);
        assert!(matches!(check_program(bad), ProgramCheck::Refused { location: Some((1, _)), .. }));
    } else {
        assert_eq!(check_program(ok), ProgramCheck::NotChecked);
        assert_eq!(check_program(bad), ProgramCheck::NotChecked);
    }
}

#[cfg(feature = "compile")]
#[test]
fn the_source_cap_is_the_programs() {
    assert_eq!(MAX_SOURCE_BYTES, program::MAX_SOURCE_BYTES);
}
