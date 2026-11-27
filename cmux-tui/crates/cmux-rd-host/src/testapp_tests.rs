#[test]
fn origin_is_two_pixel_numbers() {
    assert_eq!(super::parse_origin("1920,0").unwrap(), (1920, 0));
    assert_eq!(super::parse_origin(" 8 , 16 ").unwrap(), (8, 16));
    assert!(super::parse_origin("1920").is_err());
    assert!(super::parse_origin("-1,0").is_err());
}

#[test]
fn geometry_reads_as_x_writes_it() {
    assert_eq!(super::parse_geometry("800x600+200+150"), Ok((200, 150, 800, 600)));
    assert!(super::parse_geometry("800x600").is_err());
    assert!(super::parse_geometry("0x600+0+0").is_err());
}
