use super::*;

#[test]
fn options_map_to_inches() {
    let args = print_args(&json!({})).unwrap();
    assert_eq!(
        (args["paperWidth"].as_f64(), args["paperHeight"].as_f64()),
        (Some(8.5), Some(11.0))
    );
    let args = print_args(&json!({"format": "A4", "landscape": true, "printBackground": true,
            "margin": {"top": "1in", "left": "2.54cm", "bottom": "25.4mm", "right": 96}}))
    .unwrap();
    assert_eq!(
        (args["paperWidth"].as_f64(), args["paperHeight"].as_f64()),
        (Some(8.27), Some(11.7))
    );
    assert_eq!(
        (args["landscape"].as_bool(), args["printBackground"].as_bool()),
        (Some(true), Some(true))
    );
    for key in ["marginTop", "marginLeft", "marginBottom", "marginRight"] {
        assert!((args[key].as_f64().unwrap() - 1.0).abs() < 1e-9, "{key}: {args}");
    }
    let args = print_args(&json!({"width": "480px", "height": "5in"})).unwrap();
    assert_eq!((args["paperWidth"].as_f64(), args["paperHeight"].as_f64()), (Some(5.0), Some(5.0)));
    assert!(print_args(&json!({"format": "B5"})).is_err());
    assert!(print_args(&json!({"width": "wide"})).is_err());
    assert!(print_args(&json!({"margin": {"top": "-1in"}})).is_err());
}
