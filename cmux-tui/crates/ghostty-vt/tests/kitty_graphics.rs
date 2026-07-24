use ghostty_vt::{Callbacks, Error, KittyImageFormat, RenderState, Terminal};

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

fn assert_inflight_replay_completes(
    source: &mut Terminal,
    image_id: u32,
    first_chunk: &[u8],
    final_chunk: &[u8],
) {
    source.vt_write(first_chunk);
    assert!(source.kitty_graphics_snapshot().unwrap().image(image_id).is_none());

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    mirror.vt_write(final_chunk);

    assert_eq!(
        &*mirror
            .kitty_graphics_snapshot()
            .unwrap()
            .image(image_id)
            .expect("replayed in-flight transmission must accept its final chunk")
            .data,
        &[255; 6]
    );
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
    assert_eq!((placement.columns, placement.rows), (2, 3));
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

    let replay = source.vt_replay_bytes().unwrap();
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
fn replay_preserves_native_and_single_axis_placement_sizing() {
    let mut source = terminal();
    source.vt_write(&kitty(
        "a=t,t=d,f=24,i=23,s=20,v=10,q=2",
        &encode_base64(&vec![255; 20 * 10 * 3]),
    ));
    source.vt_write(&kitty("a=p,i=23,p=1,C=1,q=2", ""));
    source.vt_write(b"\x1b[2;1H");
    source.vt_write(&kitty("a=p,i=23,p=2,c=2,C=1,q=2", ""));
    source.vt_write(b"\x1b[3;1H");
    source.vt_write(&kitty("a=p,i=23,p=3,r=2,C=1,q=2", ""));

    let replay = source.vt_replay_bytes().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay);
    let actual = mirror.kitty_graphics_snapshot().unwrap();
    let sizing = |placement_id| {
        let placement = actual
            .placements
            .iter()
            .find(|placement| placement.placement_id == placement_id)
            .unwrap();
        (placement.columns, placement.rows)
    };
    assert_eq!(sizing(1), (0, 0));
    assert_eq!(sizing(2), (2, 0));
    assert_eq!(sizing(3), (0, 2));
}

#[test]
fn replay_keeps_an_unplaced_image_for_a_post_attach_placement() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=22,s=1,v=1,q=2", "/wAA"));
    let before_place = source.kitty_graphics_snapshot().unwrap();
    assert!(before_place.image(22).is_some());
    assert!(before_place.placements.is_empty());

    let replay = source.vt_replay_bytes().unwrap();
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
fn replay_keeps_a_number_only_image_for_a_post_attach_number_placement() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,I=77,s=1,v=1,q=2", "/wAA"));

    source.vt_write(&kitty("a=p,I=77,p=99,c=1,r=1,q=2", ""));
    let assigned_id = source.kitty_graphics_snapshot().unwrap().placements[0].image_id;
    source.vt_write(&kitty(&format!("a=d,d=i,i={assigned_id},p=99,q=2"), ""));
    assert!(source.kitty_graphics_snapshot().unwrap().placements.is_empty());

    let replay = source.vt_replay().unwrap();
    assert_eq!(
        replay.kitty_image_aliases,
        vec![ghostty_vt::KittyImageAlias { image_id: assigned_id, image_number: 77 }]
    );
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();

    let place_by_number = kitty("a=p,I=77,p=8,c=1,r=1,q=2", "");
    let place_by_id = kitty(&format!("a=p,i={assigned_id},p=9,c=1,r=1,q=2"), "");
    for place in [&place_by_number, &place_by_id] {
        source.vt_write(place);
        mirror.vt_write(place);
    }
    assert_eq!(source.kitty_graphics_snapshot().unwrap().placements.len(), 2);
    let mirrored = mirror.kitty_graphics_snapshot().unwrap();
    assert_eq!(mirrored.placements.len(), 2);
    assert!(mirrored.placements.iter().all(|placement| placement.image_id == assigned_id));
    assert_eq!(
        mirrored.placements.iter().map(|placement| placement.placement_id).collect::<Vec<_>>(),
        vec![8, 9]
    );
}

#[test]
fn replay_preserves_duplicate_number_history_and_source_generation_order() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,I=77,s=1,v=1,q=2", "/wAA"));
    let first_id = source.kitty_graphics_snapshot().unwrap().images[0].id;
    source.vt_write(&kitty("a=t,t=d,f=24,I=77,s=1,v=1,q=2", "AP8A"));
    let source_images = source.kitty_graphics_snapshot().unwrap().images;
    let newest_id =
        source_images.iter().max_by_key(|image| image.generation).expect("newest image").id;
    assert_ne!(first_id, newest_id);

    let replay = source.vt_replay().unwrap();
    assert_eq!(replay.kitty_image_aliases.len(), 2);
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();

    let delete_newest = kitty(&format!("a=d,d=I,i={newest_id},q=2"), "");
    source.vt_write(&delete_newest);
    mirror.vt_write(&delete_newest);
    let place_older = kitty("a=p,I=77,p=10,c=1,r=1,q=2", "");
    source.vt_write(&place_older);
    mirror.vt_write(&place_older);
    assert_eq!(source.kitty_graphics_snapshot().unwrap().placements[0].image_id, first_id);
    assert_eq!(mirror.kitty_graphics_snapshot().unwrap().placements[0].image_id, first_id);
}

#[test]
fn replay_aliases_follow_generation_order_and_exclude_omitted_images() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=90,s=1,v=1,q=2", "/wAA"));
    source.vt_write(&kitty("a=t,t=d,f=24,i=10,s=1,v=1,q=2", "AP8A"));
    source
        .restore_kitty_image_aliases(&[
            ghostty_vt::KittyImageAlias { image_id: 90, image_number: 88 },
            ghostty_vt::KittyImageAlias { image_id: 10, image_number: 88 },
        ])
        .unwrap();
    source.vt_write(&kitty("a=t,t=d,f=24,i=91,s=100,v=1,q=2", &encode_base64(&vec![255; 300])));
    source
        .restore_kitty_image_aliases(&[ghostty_vt::KittyImageAlias {
            image_id: 91,
            image_number: 91,
        }])
        .unwrap();

    let full = source.vt_replay().unwrap();
    assert_eq!(
        full.kitty_image_aliases,
        vec![
            ghostty_vt::KittyImageAlias { image_id: 90, image_number: 88 },
            ghostty_vt::KittyImageAlias { image_id: 10, image_number: 88 },
            ghostty_vt::KittyImageAlias { image_id: 91, image_number: 91 },
        ]
    );
    let mut mirror = terminal();
    mirror.vt_write(&full.bytes);
    mirror.restore_kitty_image_aliases(&full.kitty_image_aliases).unwrap();
    mirror.vt_write(&kitty("a=p,I=88,p=11,c=1,r=1,q=2", ""));
    assert_eq!(mirror.kitty_graphics_snapshot().unwrap().placements[0].image_id, 10);

    let bounded = source.vt_replay_bounded(256).unwrap();
    assert!(
        bounded.kitty_image_aliases.iter().all(|alias| alias.image_id != 91),
        "alias sidecar must not name an image omitted from bounded replay"
    );
    assert!(!String::from_utf8_lossy(&bounded.bytes).contains("i=91"));
}

#[test]
fn replay_preserves_an_inflight_chunked_transmission_until_its_final_chunk() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=92,s=1,v=2,m=1,q=2", "////"));
    assert!(source.kitty_graphics_snapshot().unwrap().image(92).is_none());

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();

    let final_chunk = kitty("m=0,q=2", "////");
    source.vt_write(&final_chunk);
    mirror.vt_write(&final_chunk);
    assert_eq!(&*source.kitty_graphics_snapshot().unwrap().image(92).unwrap().data, &[255; 6]);
    assert_eq!(&*mirror.kitty_graphics_snapshot().unwrap().image(92).unwrap().data, &[255; 6]);
}

#[test]
fn utf8_emoji_before_chunked_transmission_does_not_hide_its_replay_prefix() {
    let mut source = terminal();
    source.vt_write("😀".as_bytes());
    assert_inflight_replay_completes(
        &mut source,
        192,
        &kitty("a=t,t=d,f=24,i=192,s=1,v=2,m=1,q=2", "////"),
        &kitty("m=0,q=2", "////"),
    );
}

#[test]
fn split_utf8_scalar_before_chunked_transmission_does_not_hide_its_replay_prefix() {
    let mut source = terminal();
    let emoji = "😀".as_bytes();
    source.vt_write(&emoji[..2]);
    source.vt_write(&emoji[2..]);
    assert_inflight_replay_completes(
        &mut source,
        193,
        &kitty("a=t,t=d,f=24,i=193,s=1,v=2,m=1,q=2", "////"),
        &kitty("m=0,q=2", "////"),
    );
}

#[test]
fn invalid_utf8_resynchronizes_before_a_chunked_transmission() {
    let mut source = terminal();
    source.vt_write(&[0xf0, 0x9f]);
    assert_inflight_replay_completes(
        &mut source,
        194,
        &kitty("a=t,t=d,f=24,i=194,s=1,v=2,m=1,q=2", "////"),
        &kitty("m=0,q=2", "////"),
    );
}

#[test]
fn bare_c1_kitty_apc_chunked_transmission_remains_replayable() {
    let mut source = terminal();
    let first = b"\x9fGa=t,t=d,f=24,i=195,s=1,v=2,m=1,q=2;////\x9c";
    source.vt_write(first);

    assert!(
        source.vt_replay().unwrap().bytes.ends_with(first),
        "a genuine bare C1 Kitty APC must remain part of attach replay"
    );
}

#[test]
fn replay_preserves_image_eviction_age_when_ids_sort_in_the_opposite_order() {
    let mut source = terminal();
    source.set_kitty_image_storage_limit(6).unwrap();
    source.set_kitty_image_count_limit(2).unwrap();
    source.vt_write(&kitty("a=t,t=d,f=24,i=90,s=1,v=1,q=2", "/wAA"));
    source.vt_write(&kitty("a=t,t=d,f=24,i=10,s=1,v=1,q=2", "AP8A"));

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.set_kitty_image_storage_limit(6).unwrap();
    mirror.set_kitty_image_count_limit(2).unwrap();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();

    let newest = kitty("a=t,t=d,f=24,i=50,s=1,v=1,q=2", "AAD/");
    source.vt_write(&newest);
    mirror.vt_write(&newest);
    let image_ids = |terminal: &mut Terminal| {
        terminal
            .kitty_graphics_snapshot()
            .unwrap()
            .images
            .iter()
            .map(|image| image.id)
            .collect::<Vec<_>>()
    };

    assert_eq!(image_ids(&mut source), vec![10, 50]);
    assert_eq!(image_ids(&mut mirror), image_ids(&mut source));
}

#[test]
fn anonymous_transmission_after_replay_uses_an_unoccupied_image_id() {
    const FIRST_AUTOMATIC_ID: u32 = 2_147_483_647;
    let mut source = terminal();
    source.vt_write(&kitty(&format!("a=t,t=d,f=24,i={FIRST_AUTOMATIC_ID},s=1,v=1,q=2"), "/wAA"));
    source.vt_write(&kitty("a=t,t=d,f=24,i=7,s=1,v=1,q=2", "AP8A"));
    let expected = source
        .kitty_graphics_snapshot()
        .unwrap()
        .images
        .iter()
        .map(|image| (image.id, image.data.to_vec()))
        .collect::<Vec<_>>();

    let replay = source.vt_replay().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    mirror.vt_write(&kitty("a=t,t=d,f=24,s=1,v=1,q=2", "AAD/"));

    let snapshot = mirror.kitty_graphics_snapshot().unwrap();
    assert_eq!(snapshot.images.len(), 3);
    for (image_id, pixels) in expected {
        assert_eq!(&*snapshot.image(image_id).expect("replayed image").data, pixels);
    }
    let anonymous = snapshot
        .images
        .iter()
        .find(|image| image.id != FIRST_AUTOMATIC_ID && image.id != 7)
        .expect("anonymous image must use an unoccupied ID");
    assert_eq!(&*anonymous.data, &[0, 0, 255]);
}

#[test]
fn bounded_replay_uses_the_full_cap_for_a_large_visible_image() {
    let mut source = terminal();
    let pixels = vec![127; 80 * 40 * 3];
    source.vt_write(b"visible image");
    source
        .vt_write(&kitty("a=T,t=d,f=24,i=93,p=1,s=80,v=40,c=10,r=4,q=2", &encode_base64(&pixels)));
    let full = source.vt_replay().unwrap();
    assert!(
        encode_base64(&pixels).len() > full.bytes.len() / 2,
        "fixture must exceed the old half-budget"
    );

    let bounded = source.vt_replay_bounded(full.bytes.len()).unwrap();
    assert!(bounded.bytes.len() <= full.bytes.len());
    let mut mirror = terminal();
    mirror.vt_write(&bounded.bytes);
    mirror.restore_kitty_image_aliases(&bounded.kitty_image_aliases).unwrap();

    let snapshot = mirror.kitty_graphics_snapshot().unwrap();
    assert_eq!(&*snapshot.image(93).expect("visible image must fit the total cap").data, &pixels);
    assert_eq!(snapshot.placements.len(), 1);
}

#[test]
fn bounded_replay_prioritizes_a_visible_image_over_an_older_unplaced_image() {
    let pixels = vec![64; 600 * 3];
    let mut visible_only = terminal();
    visible_only.vt_write(b"same text");
    visible_only
        .vt_write(&kitty("a=T,t=d,f=24,i=95,p=1,s=600,v=1,c=10,r=1,q=2", &encode_base64(&pixels)));
    let budget = visible_only.vt_replay().unwrap().bytes.len();

    let mut source = terminal();
    source.vt_write(b"same text");
    source.vt_write(&kitty("a=t,t=d,f=24,i=94,s=600,v=1,q=2", &encode_base64(&pixels)));
    source
        .vt_write(&kitty("a=T,t=d,f=24,i=95,p=1,s=600,v=1,c=10,r=1,q=2", &encode_base64(&pixels)));

    let replay = source.vt_replay_bounded(budget).unwrap();
    assert!(replay.bytes.len() <= budget);
    let mut mirror = terminal();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    let snapshot = mirror.kitty_graphics_snapshot().unwrap();

    assert!(snapshot.image(95).is_some(), "visible image was starved by an unplaced image");
    assert!(snapshot.placements.iter().any(|placement| placement.image_id == 95));
    assert!(snapshot.image(94).is_none(), "tight replay unexpectedly retained both images");
}

fn visible_placement_signature(terminal: &mut Terminal) -> Vec<(u32, i32, u32, u32, u32)> {
    terminal
        .kitty_graphics_snapshot()
        .unwrap()
        .placements
        .iter()
        .filter(|placement| placement.viewport_visible)
        .map(|placement| {
            (
                placement.image_id,
                placement.viewport_row,
                placement.grid_rows,
                placement.source_y,
                placement.source_height,
            )
        })
        .collect()
}

#[test]
fn replay_preserves_scrollback_placements_before_and_after_resize() {
    let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    source.resize(12, 4, 10, 20).unwrap();
    source.vt_write(&kitty("a=t,t=d,f=24,i=96,s=1,v=1,q=2", "/wAA"));
    source.vt_write(&kitty("a=t,t=d,f=24,i=97,s=1,v=1,q=2", "AP8A"));
    source.vt_write(&kitty("a=p,i=96,p=1,c=1,r=2,q=2", ""));
    source.vt_write(b"row-0\r\nrow-1\r\n");
    source.vt_write(&kitty("a=p,i=97,p=2,c=1,r=3,q=2", ""));
    for row in 2..=3 {
        source.vt_write(format!("row-{row}\r\n").as_bytes());
    }
    source.vt_write(b"tail");
    let source_bottom = source.kitty_graphics_snapshot().unwrap();
    assert!(
        source_bottom
            .placements
            .iter()
            .any(|placement| placement.image_id == 96 && !placement.viewport_visible)
    );
    assert!(
        source_bottom.placements.iter().any(|placement| {
            placement.image_id == 97 && placement.viewport_visible && placement.viewport_row < 0
        }),
        "fixture placements: {:?}",
        source_bottom.placements
    );

    let replay = source.vt_replay().unwrap();
    let mut mirror = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    mirror.resize(12, 4, 10, 20).unwrap();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();
    assert_eq!(
        mirror
            .kitty_graphics_snapshot()
            .unwrap()
            .placements
            .iter()
            .map(|placement| placement.image_id)
            .collect::<Vec<_>>(),
        vec![96, 97],
        "byte replay must retain fully and partially offscreen placements"
    );

    source.scroll_delta(-3);
    mirror.scroll_delta(-3);
    assert_eq!(visible_placement_signature(&mut mirror), visible_placement_signature(&mut source));

    source.resize(12, 6, 10, 20).unwrap();
    mirror.resize(12, 6, 10, 20).unwrap();
    source.scroll_to_bottom();
    mirror.scroll_to_bottom();
    source.scroll_delta(-3);
    mirror.scroll_delta(-3);
    assert_eq!(visible_placement_signature(&mut mirror), visible_placement_signature(&mut source));
}

#[test]
fn replay_preserves_graphics_across_blank_only_scrollback_rows() {
    let mut source = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    source.resize(12, 4, 10, 20).unwrap();
    source.vt_write(&kitty("a=t,t=d,f=24,i=98,s=1,v=1,q=2", "/wAA"));
    for _ in 0..6 {
        source.vt_write(b"\r\n");
    }
    source.vt_write(&kitty("a=p,i=98,p=1,c=1,r=2,q=2", ""));
    source.vt_write(b"\r\n\r\ntail");

    let expected = source.kitty_graphics_snapshot().unwrap();
    assert_eq!(expected.placements.len(), 1);
    let replay = source.vt_replay().unwrap();
    let mut mirror = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    mirror.resize(12, 4, 10, 20).unwrap();
    mirror.vt_write(&replay.bytes);
    mirror.restore_kitty_image_aliases(&replay.kitty_image_aliases).unwrap();

    let actual = mirror.kitty_graphics_snapshot().unwrap();
    assert_eq!(
        actual
            .placements
            .iter()
            .map(|placement| (
                placement.image_id,
                placement.viewport_row,
                placement.viewport_visible,
            ))
            .collect::<Vec<_>>(),
        expected
            .placements
            .iter()
            .map(|placement| (
                placement.image_id,
                placement.viewport_row,
                placement.viewport_visible,
            ))
            .collect::<Vec<_>>()
    );

    source.scroll_delta(-4);
    mirror.scroll_delta(-4);
    assert_eq!(visible_placement_signature(&mut mirror), visible_placement_signature(&mut source));
}

#[test]
fn bounded_replay_reports_an_inflight_prefix_that_cannot_fit() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=98,s=1,v=2,m=1,q=2", "////"));

    assert_eq!(source.vt_replay_bounded(16), Err(Error::OutOfSpace));
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
fn object_count_limits_bound_images_and_placements_across_reset() {
    let mut terminal = terminal();
    assert_eq!(terminal.kitty_image_count_limit().unwrap(), 4_096);
    assert_eq!(terminal.kitty_placement_count_limit().unwrap(), 16_384);

    terminal.set_kitty_image_count_limit(2).unwrap();
    terminal.set_kitty_placement_count_limit(2).unwrap();
    for image_id in 31..=33 {
        terminal.vt_write(&kitty(&format!("a=t,t=d,f=24,i={image_id},s=1,v=1,q=2"), "/wAA"));
    }
    assert_eq!(
        terminal
            .kitty_graphics_snapshot()
            .unwrap()
            .images
            .iter()
            .map(|image| image.id)
            .collect::<Vec<_>>(),
        vec![32, 33]
    );

    for placement_id in 1..=3 {
        terminal.vt_write(&kitty(&format!("a=p,i=33,p={placement_id},c=1,r=1,q=2"), ""));
    }
    assert_eq!(
        terminal
            .kitty_graphics_snapshot()
            .unwrap()
            .placements
            .iter()
            .map(|placement| placement.placement_id)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );

    terminal.vt_write(b"\x1bc");
    assert_eq!(terminal.kitty_image_count_limit().unwrap(), 2);
    assert_eq!(terminal.kitty_placement_count_limit().unwrap(), 2);
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
    assert!(snapshot.placements.iter().all(|placement| placement.is_internal));
    assert_ne!(snapshot.placements[0].placement_id, snapshot.placements[1].placement_id);
    assert_ne!(snapshot.placements[0].key, snapshot.placements[1].key);
}

#[test]
fn replay_keeps_anonymous_placements_separate_from_later_explicit_ids() {
    let mut source = terminal();
    source.vt_write(&kitty("a=t,t=d,f=24,i=51,s=1,v=1,q=2", "/wAA"));
    source.vt_write(b"\x1b[1;1H");
    source.vt_write(&kitty("a=p,i=51,p=0,c=1,r=1,q=2", ""));
    source.vt_write(b"\x1b[2;2H");
    source.vt_write(&kitty("a=p,i=51,p=0,c=1,r=1,q=2", ""));

    let replay = source.vt_replay_bytes().unwrap();
    let mut mirror = terminal();
    mirror.vt_write(&replay);

    let explicit = kitty("a=p,i=51,p=1,c=1,r=1,q=2", "");
    source.vt_write(b"\x1b[3;3H");
    mirror.vt_write(b"\x1b[3;3H");
    source.vt_write(&explicit);
    mirror.vt_write(&explicit);

    assert_eq!(source.kitty_graphics_snapshot().unwrap().placements.len(), 3);
    assert_eq!(mirror.kitty_graphics_snapshot().unwrap().placements.len(), 3);
}
