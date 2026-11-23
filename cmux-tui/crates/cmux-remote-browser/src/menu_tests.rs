use super::*;

#[test]
fn tokens_never_repeat() {
    let mut m = MenuTokens::default();
    let mut seen = Vec::new();
    for _ in 0..5 {
        let out = m
            .apply(MenuInput::Show {
                kind: MenuKind::Context,
                item_ids: vec![1],
                item_count: 0,
                multiple: false,
            })
            .unwrap();
        let Some(MenuEffect::ViewerShow { token }) = out.effects.last().cloned() else {
            panic!("no show effect");
        };
        assert!(!seen.contains(&token));
        seen.push(token);
    }
}
