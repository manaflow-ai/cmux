use crate::style::{Color, Colors};

#[test]
fn test_colors_then() {
    use Color::*;

    assert_eq!(
        Colors { foreground: None, background: None }
            .then(&Colors { foreground: None, background: None }),
        Colors { foreground: None, background: None }
    );

    assert_eq!(
        Colors { foreground: None, background: None }
            .then(&Colors { foreground: Some(Black), background: None }),
        Colors { foreground: Some(Black), background: None }
    );

    assert_eq!(
        Colors { foreground: None, background: None }
            .then(&Colors { foreground: None, background: Some(Grey) }),
        Colors { foreground: None, background: Some(Grey) }
    );

    assert_eq!(
        Colors { foreground: None, background: None }.then(&Colors::new(White, Grey)),
        Colors::new(White, Grey),
    );

    assert_eq!(
        Colors { foreground: None, background: Some(Blue) }.then(&Colors::new(White, Grey)),
        Colors::new(White, Grey),
    );

    assert_eq!(
        Colors { foreground: Some(Blue), background: None }.then(&Colors::new(White, Grey)),
        Colors::new(White, Grey),
    );

    assert_eq!(Colors::new(Blue, Green).then(&Colors::new(White, Grey)), Colors::new(White, Grey),);

    assert_eq!(
        Colors { foreground: Some(Blue), background: Some(Green) }
            .then(&Colors { foreground: None, background: Some(Grey) }),
        Colors { foreground: Some(Blue), background: Some(Grey) }
    );

    assert_eq!(
        Colors { foreground: Some(Blue), background: Some(Green) }
            .then(&Colors { foreground: Some(White), background: None }),
        Colors { foreground: Some(White), background: Some(Green) }
    );

    assert_eq!(
        Colors { foreground: Some(Blue), background: Some(Green) }
            .then(&Colors { foreground: None, background: None }),
        Colors { foreground: Some(Blue), background: Some(Green) }
    );

    assert_eq!(
        Colors { foreground: None, background: Some(Green) }
            .then(&Colors { foreground: None, background: None }),
        Colors { foreground: None, background: Some(Green) }
    );

    assert_eq!(
        Colors { foreground: Some(Blue), background: None }
            .then(&Colors { foreground: None, background: None }),
        Colors { foreground: Some(Blue), background: None }
    );
}
