use super::*;

#[test]
fn a_two_core_machine_converts_on_one_thread() {
    let threads: Vec<usize> = [1, 2, 3, 4, 8, 16, 64].map(threads_for_cores).to_vec();
    assert_eq!(threads, [1, 1, 1, 2, 4, 4, 4]);
}

#[test]
fn every_thread_count_converts_the_same_picture() {
    let (w, h) = (640, 480);
    let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 37 % 251) as u8).collect();
    let mut one = I420::new(w, h);
    bgrx_rect_to_i420(&src, &mut one, 0, 0, w, h, 1);
    for threads in [2, 3, 4] {
        let mut many = I420::new(w, h);
        bgrx_rect_to_i420(&src, &mut many, 0, 0, w, h, threads);
        assert_eq!(many, one, "{threads} threads");
    }
}
