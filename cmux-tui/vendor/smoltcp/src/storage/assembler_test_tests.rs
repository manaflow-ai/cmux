use super::*;
use std::vec::Vec;

impl From<Vec<(usize, usize)>> for Assembler {
    fn from(vec: Vec<(usize, usize)>) -> Assembler {
        const EMPTY: Contig = Contig::empty();

        let mut contigs = [EMPTY; ASSEMBLER_MAX_SEGMENT_COUNT];
        for (i, &(hole_size, data_size)) in vec.iter().enumerate() {
            contigs[i] = Contig {
                hole_size,
                data_size,
            };
        }
        Assembler { contigs }
    }
}

macro_rules! contigs {
    [$( $x:expr ),*] => ({
        Assembler::from(vec![$( $x ),*])
    })
}

#[test]
fn test_new() {
    let assr = Assembler::new();
    assert_eq!(assr, contigs![]);
}

#[test]
fn test_empty_add_full() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(0, 16), Ok(()));
    assert_eq!(assr, contigs![(0, 16)]);
}

#[test]
fn test_empty_add_front() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(0, 4), Ok(()));
    assert_eq!(assr, contigs![(0, 4)]);
}

#[test]
fn test_empty_add_back() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(12, 4), Ok(()));
    assert_eq!(assr, contigs![(12, 4)]);
}

#[test]
fn test_empty_add_mid() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(4, 8), Ok(()));
    assert_eq!(assr, contigs![(4, 8)]);
}

#[test]
fn test_partial_add_front() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(0, 4), Ok(()));
    assert_eq!(assr, contigs![(0, 12)]);
}

#[test]
fn test_partial_add_back() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(12, 4), Ok(()));
    assert_eq!(assr, contigs![(4, 12)]);
}

#[test]
fn test_partial_add_front_overlap() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(0, 8), Ok(()));
    assert_eq!(assr, contigs![(0, 12)]);
}

#[test]
fn test_partial_add_front_overlap_split() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(2, 6), Ok(()));
    assert_eq!(assr, contigs![(2, 10)]);
}

#[test]
fn test_partial_add_back_overlap() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(8, 8), Ok(()));
    assert_eq!(assr, contigs![(4, 12)]);
}

#[test]
fn test_partial_add_back_overlap_split() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(10, 4), Ok(()));
    assert_eq!(assr, contigs![(4, 10)]);
}

#[test]
fn test_partial_add_both_overlap() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(0, 16), Ok(()));
    assert_eq!(assr, contigs![(0, 16)]);
}

#[test]
fn test_partial_add_both_overlap_split() {
    let mut assr = contigs![(4, 8)];
    assert_eq!(assr.add(2, 12), Ok(()));
    assert_eq!(assr, contigs![(2, 12)]);
}

#[test]
fn test_rejected_add_keeps_state() {
    let mut assr = Assembler::new();
    for c in 1..=ASSEMBLER_MAX_SEGMENT_COUNT {
        assert_eq!(assr.add(c * 10, 3), Ok(()));
    }
    // Maximum of allowed holes is reached
    let assr_before = assr.clone();
    assert_eq!(assr.add(1, 3), Err(TooManyHolesError));
    assert_eq!(assr_before, assr);
}

#[test]
fn test_empty_remove_front() {
    let mut assr = contigs![];
    assert_eq!(assr.remove_front(), 0);
}

#[test]
fn test_trailing_hole_remove_front() {
    let mut assr = contigs![(0, 4)];
    assert_eq!(assr.remove_front(), 4);
    assert_eq!(assr, contigs![]);
}

#[test]
fn test_trailing_data_remove_front() {
    let mut assr = contigs![(0, 4), (4, 4)];
    assert_eq!(assr.remove_front(), 4);
    assert_eq!(assr, contigs![(4, 4)]);
}

#[test]
fn test_boundary_case_remove_front() {
    let mut vec = vec![(1, 1); ASSEMBLER_MAX_SEGMENT_COUNT];
    vec[0] = (0, 2);
    let mut assr = Assembler::from(vec);
    assert_eq!(assr.remove_front(), 2);
    let mut vec = vec![(1, 1); ASSEMBLER_MAX_SEGMENT_COUNT];
    vec[ASSEMBLER_MAX_SEGMENT_COUNT - 1] = (0, 0);
    let exp_assr = Assembler::from(vec);
    assert_eq!(assr, exp_assr);
}

#[test]
fn test_shrink_next_hole() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(100, 10), Ok(()));
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add(40, 30), Ok(()));
    assert_eq!(assr, contigs![(40, 30), (30, 10)]);
}

#[test]
fn test_join_two() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(10, 10), Ok(()));
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add(15, 40), Ok(()));
    assert_eq!(assr, contigs![(10, 50)]);
}

#[test]
fn test_join_two_reversed() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add(10, 10), Ok(()));
    assert_eq!(assr.add(15, 40), Ok(()));
    assert_eq!(assr, contigs![(10, 50)]);
}

#[test]
fn test_join_two_overlong() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add(10, 10), Ok(()));
    assert_eq!(assr.add(15, 60), Ok(()));
    assert_eq!(assr, contigs![(10, 65)]);
}

#[test]
fn test_iter_empty() {
    let assr = Assembler::new();
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![]);
}

#[test]
fn test_iter_full() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(0, 16), Ok(()));
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(0, 16)]);
}

#[test]
fn test_iter_one_front() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(0, 4), Ok(()));
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(0, 4)]);
}

#[test]
fn test_iter_one_back() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(12, 4), Ok(()));
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(12, 16)]);
}

#[test]
fn test_iter_one_mid() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(4, 8), Ok(()));
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(4, 12)]);
}

#[test]
fn test_iter_one_trailing_gap() {
    let assr = contigs![(4, 8)];
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(4, 12)]);
}

#[test]
fn test_iter_two_split() {
    let assr = contigs![(2, 6), (4, 1)];
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(2, 8), (12, 13)]);
}

#[test]
fn test_iter_three_split() {
    let assr = contigs![(2, 6), (2, 1), (2, 2)];
    let segments: Vec<_> = assr.iter_data().collect();
    assert_eq!(segments, vec![(2, 8), (10, 11), (13, 15)]);
}

#[test]
fn test_issue_694() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(0, 1), Ok(()));
    assert_eq!(assr.add(2, 1), Ok(()));
    assert_eq!(assr.add(1, 1), Ok(()));
}

#[test]
fn test_add_then_remove_front() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add_then_remove_front(10, 10), Ok(0));
    assert_eq!(assr, contigs![(10, 10), (30, 10)]);
}

#[test]
fn test_add_then_remove_front_at_front() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add_then_remove_front(0, 10), Ok(10));
    assert_eq!(assr, contigs![(40, 10)]);
}

#[test]
fn test_add_then_remove_front_at_front_touch() {
    let mut assr = Assembler::new();
    assert_eq!(assr.add(50, 10), Ok(()));
    assert_eq!(assr.add_then_remove_front(0, 50), Ok(60));
    assert_eq!(assr, contigs![]);
}

#[test]
fn test_add_then_remove_front_at_front_full() {
    let mut assr = Assembler::new();
    for c in 1..=ASSEMBLER_MAX_SEGMENT_COUNT {
        assert_eq!(assr.add(c * 10, 3), Ok(()));
    }
    // Maximum of allowed holes is reached
    let assr_before = assr.clone();
    assert_eq!(assr.add_then_remove_front(1, 3), Err(TooManyHolesError));
    assert_eq!(assr_before, assr);
}

#[test]
fn test_add_then_remove_front_at_front_full_offset_0() {
    let mut assr = Assembler::new();
    for c in 1..=ASSEMBLER_MAX_SEGMENT_COUNT {
        assert_eq!(assr.add(c * 10, 3), Ok(()));
    }
    assert_eq!(assr.add_then_remove_front(0, 3), Ok(3));
}

// Test against an obviously-correct but inefficient bitmap impl.
#[test]
fn test_random() {
    use rand::Rng;

    const MAX_INDEX: usize = 256;

    for max_size in [2, 5, 10, 100] {
        for _ in 0..300 {
            //println!("===");
            let mut assr = Assembler::new();
            let mut map = [false; MAX_INDEX];

            for _ in 0..60 {
                let offset = rand::thread_rng().gen_range(0..MAX_INDEX - max_size - 1);
                let size = rand::thread_rng().gen_range(1..=max_size);

                //println!("add {}..{} {}", offset, offset + size, size);
                // Real impl
                let res = assr.add(offset, size);

                // Bitmap impl
                let mut map2 = map;
                map2[offset..][..size].fill(true);

                let mut contigs = vec![];
                let mut hole: usize = 0;
                let mut data: usize = 0;
                for b in map2 {
                    if b {
                        data += 1;
                    } else {
                        if data != 0 {
                            contigs.push((hole, data));
                            hole = 0;
                            data = 0;
                        }
                        hole += 1;
                    }
                }

                // Compare.
                let wanted_res = if contigs.len() > ASSEMBLER_MAX_SEGMENT_COUNT {
                    Err(TooManyHolesError)
                } else {
                    Ok(())
                };
                assert_eq!(res, wanted_res);
                if res.is_ok() {
                    map = map2;
                    assert_eq!(assr, Assembler::from(contigs));
                }
            }
        }
    }
}
