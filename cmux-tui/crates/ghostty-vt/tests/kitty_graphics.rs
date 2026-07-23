use ghostty_vt::{Callbacks, KittyImageFormat, RenderState, Terminal};

const PNG_1X1_RED: &str = concat!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA",
    "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
);

fn terminal() -> Terminal {
    let mut terminal = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    terminal.resize(20, 8, 10, 20).unwrap();
    terminal
}

fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        encoded.push(ALPHABET[(a >> 2) as usize] as char);
        encoded.push(ALPHABET[(((a & 0x03) << 4) | (b >> 4)) as usize] as char);
        encoded.push(if chunk.len() > 1 {
            ALPHABET[(((b & 0x0f) << 2) | (c >> 6)) as usize] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() > 2 { ALPHABET[(c & 0x3f) as usize] as char } else { '=' });
    }
    encoded
}

fn kitty(params: &str, payload: &str) -> Vec<u8> {
    format!("\x1b_G{params};{payload}\x1b\\").into_bytes()
}

#[test]
fn chunked_rgb_transmission_is_snapshotted_as_owned_pixels() {
    let mut terminal = terminal();
    terminal.vt_write(&kitty("a=t,t=d,f=24,i=7,s=1,v=2,m=1,q=2", "////"));
    terminal.vt_write(&kitty("m=0,q=2", "////"));
    terminal.vt_write(&kitty("a=p,i=7,p=3,c=2,r=1,q=2", ""));

    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(7).expect("image");
    assert_eq!(image.format, KittyImageFormat::Rgb);
    assert_eq!((image.width, image.height), (1, 2));
    assert_eq!(&*image.data, &[255; 6]);
    assert_eq!(snapshot.placements.len(), 1);

    terminal.vt_write(&kitty("a=d,d=I,i=7,q=2", ""));
    assert!(terminal.kitty_graphics_snapshot().unwrap().images.is_empty());
    assert_eq!(&*image.data, &[255; 6], "snapshot pixels must outlive Ghostty's borrowed handle");
}

#[test]
fn rgba_snapshot_preserves_alpha_crop_offsets_z_and_real_cell_geometry() {
    let mut terminal = terminal();
    let pixels = [255, 0, 0, 0, 0, 255, 0, 64, 0, 0, 255, 128, 255, 255, 255, 255];
    terminal.vt_write(b"\x1b[3;4H");
    terminal.vt_write(&kitty("a=t,t=d,f=32,i=8,s=2,v=2,q=2", &encode_base64(&pixels)));
    terminal.vt_write(&kitty("a=p,i=8,p=12,x=1,y=0,w=1,h=2,X=3,Y=4,c=2,r=3,z=-2,q=2", ""));

    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(8).expect("image");
    assert_eq!(image.format, KittyImageFormat::Rgba);
    assert_eq!(&*image.data, &pixels);
    let placement = &snapshot.placements[0];
    assert_eq!((placement.viewport_col, placement.viewport_row), (3, 2));
    assert_eq!((placement.source_x, placement.source_y), (1, 0));
    assert_eq!((placement.source_width, placement.source_height), (1, 2));
    assert_eq!((placement.x_offset, placement.y_offset), (3, 4));
    assert_eq!((placement.grid_cols, placement.grid_rows), (2, 3));
    assert_eq!((placement.pixel_width, placement.pixel_height), (20, 60));
    assert_eq!(placement.z, -2);
}

#[test]
fn png_transmission_is_decoded_to_rgba() {
    let mut terminal = terminal();
    terminal.vt_write(&kitty("a=T,t=d,f=100,i=9,p=1,q=2", PNG_1X1_RED));

    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(9).expect("decoded PNG image");
    assert_eq!(image.format, KittyImageFormat::Rgba);
    assert_eq!((image.width, image.height), (1, 1));
    assert_eq!(&*image.data, &[255, 0, 0, 255]);
}

#[test]
fn oversized_png_header_is_rejected_before_decode_allocation_and_parser_recovers() {
    let mut terminal = terminal();
    let mut oversized = b"\x89PNG\r\n\x1a\n".to_vec();
    oversized.extend_from_slice(&13_u32.to_be_bytes());
    oversized.extend_from_slice(b"IHDR");
    oversized.extend_from_slice(&5_000_u32.to_be_bytes());
    oversized.extend_from_slice(&5_000_u32.to_be_bytes());
    terminal.vt_write(&kitty("a=t,t=d,f=100,i=90,q=2", &encode_base64(&oversized)));
    assert!(terminal.kitty_graphics_snapshot().unwrap().image(90).is_none());

    terminal.vt_write(&kitty("a=T,t=d,f=100,i=91,p=1,q=2", PNG_1X1_RED));
    assert_eq!(
        &*terminal.kitty_graphics_snapshot().unwrap().image(91).unwrap().data,
        &[255, 0, 0, 255]
    );
}

#[test]
fn retransmit_delete_and_malformed_input_recover_without_stale_pixels() {
    let mut terminal = terminal();
    terminal.vt_write(&kitty("a=T,t=d,f=24,i=10,p=4,s=1,v=1,q=2", "////"));
    let first = terminal.kitty_graphics_snapshot().unwrap();
    let first_image = first.image(10).unwrap();

    terminal.vt_write(&kitty("a=t,t=d,f=24,i=10,s=1,v=1,q=2", "AAAA"));
    let second = terminal.kitty_graphics_snapshot().unwrap();
    let second_image = second.image(10).unwrap();
    assert!(second_image.generation > first_image.generation);
    assert_eq!(&*second_image.data, &[0, 0, 0]);

    terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=99,s=999999999,v=2;!!!!\x1b\\");
    terminal.vt_write(&kitty("a=T,t=d,f=24,i=11,p=1,s=1,v=1,q=2", "/wAA"));
    let recovered = terminal.kitty_graphics_snapshot().unwrap();
    assert!(recovered.image(99).is_none());
    assert_eq!(&*recovered.image(11).unwrap().data, &[255, 0, 0]);

    terminal.vt_write(&kitty("a=d,d=i,i=10,p=4,q=2", ""));
    assert!(
        terminal
            .kitty_graphics_snapshot()
            .unwrap()
            .placements
            .iter()
            .all(|placement| placement.image_id != 10)
    );
    terminal.vt_write(&kitty("a=d,d=I,i=10,q=2", ""));
    assert!(terminal.kitty_graphics_snapshot().unwrap().image(10).is_none());
}

#[test]
fn replay_reconstructs_preexisting_images_and_placements() {
    let mut source = terminal();
    source.vt_write(b"before");
    source.vt_write(&kitty("a=T,t=d,f=32,i=21,p=2,s=1,v=1,c=2,r=2,z=4,q=2", "/wAAfw=="));
    let expected = source.kitty_graphics_snapshot().unwrap();

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay);
    let actual = mirror.kitty_graphics_snapshot().unwrap();

    assert_eq!(actual.images.len(), 1);
    assert_eq!(actual.placements.len(), 1);
    assert_eq!(actual.image(21).unwrap().data, expected.image(21).unwrap().data);
    assert_eq!(actual.placements[0].z, 4);
    assert_eq!((actual.placements[0].grid_cols, actual.placements[0].grid_rows), (2, 2));
}

#[test]
fn replay_keeps_an_unplaced_image_for_a_post_attach_placement() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=22,s=1,v=1,q=2", "/wAA"));
    let before_place = source.kitty_graphics_snapshot().unwrap();
    assert!(before_place.image(22).is_some());
    assert!(before_place.placements.is_empty());

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay);
    assert!(mirror.kitty_graphics_snapshot().unwrap().image(22).is_some());

    let place = kitty("a=p,i=22,p=7,c=1,r=1,q=2", "");
    source.vt_write(&place);
    mirror.vt_write(&place);
    let mirrored = mirror.kitty_graphics_snapshot().unwrap();
    assert_eq!(mirrored.placements.len(), 1);
    assert_eq!(mirrored.placements[0].placement_id, 7);
}

#[test]
fn storage_limit_bounds_retained_pixel_data() {
    let mut terminal = terminal();
    terminal.set_kitty_image_storage_limit(8).unwrap();
    assert_eq!(terminal.kitty_image_storage_limit().unwrap(), 8);
    terminal.vt_write(&kitty("a=t,t=d,f=32,i=30,s=2,v=2,q=2", &encode_base64(&[255; 16])));
    let retained = terminal
        .kitty_graphics_snapshot()
        .unwrap()
        .images
        .iter()
        .map(|image| image.data.len())
        .sum::<usize>();
    assert!(retained <= 8, "retained {retained} bytes despite an 8-byte limit");
}

#[test]
fn terminal_enables_direct_payloads_without_external_image_media() {
    let terminal = terminal();
    assert_eq!(terminal.kitty_external_image_media_enabled().unwrap(), (false, false, false));
}

#[test]
fn render_frame_owns_the_same_graphics_snapshot_as_text() {
    let mut terminal = terminal();
    terminal.vt_write(b"frame");
    terminal.vt_write(&kitty("a=T,t=d,f=24,i=40,p=1,s=1,v=1,q=2", "/wAA"));
    let mut render = RenderState::new().unwrap();
    render.update(&mut terminal).unwrap();
    let frame = render.build_frame().unwrap();

    let text =
        frame.styled_rows().iter().flatten().map(|cell| cell.text.as_str()).collect::<String>();
    assert!(text.contains("frame"));
    assert_eq!(&*frame.kitty_graphics.image(40).unwrap().data, &[255, 0, 0]);

    terminal.vt_write(&kitty("a=d,d=A,q=2", ""));
    assert_eq!(&*frame.kitty_graphics.image(40).unwrap().data, &[255, 0, 0]);
}

#[test]
fn steady_state_render_snapshot_does_not_probe_or_copy_unplaced_images() {
    let mut terminal = terminal();
    terminal.vt_write(&kitty("a=t,t=d,f=24,i=41,s=1,v=1,q=2", "/wAA"));
    assert!(terminal.kitty_graphics_snapshot().unwrap().image(41).is_some());

    let mut render = RenderState::new().unwrap();
    render.update(&mut terminal).unwrap();
    let frame = render.build_frame().unwrap();
    assert!(frame.kitty_graphics.images.is_empty());
    assert!(frame.kitty_graphics.placements.is_empty());
}

#[test]
fn anonymous_or_reused_placement_ids_have_distinct_snapshot_keys() {
    let mut terminal = terminal();
    terminal.vt_write(&kitty("a=t,t=d,f=24,i=50,s=1,v=1,q=2", "/wAA"));
    terminal.vt_write(b"\x1b[1;1H");
    terminal.vt_write(&kitty("a=p,i=50,p=0,c=1,r=1,q=2", ""));
    terminal.vt_write(b"\x1b[2;2H");
    terminal.vt_write(&kitty("a=p,i=50,p=0,c=1,r=1,q=2", ""));

    let snapshot = terminal.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.placements.len(), 2);
    assert_ne!(snapshot.placements[0].placement_id, snapshot.placements[1].placement_id);
    assert_ne!(snapshot.placements[0].key, snapshot.placements[1].key);
}
