use super::{RouteKey, RouteTable, SurfaceId};
use std::sync::Arc;

/// A key that routes no surface (no route generation moves).
impl RouteKey<u32> for u32 {
    fn routed_id(&self, _: &u32) -> Option<SurfaceId> {
        None
    }
}

/// A mutation plan reserves room before its durable commit and inserts after it, and the insert must allocate
/// nothing (`ResourceMutationPlan::apply`). With stage S1 on, a published route snapshot shares the map: the
/// reservation copies it then, before the commit, so the insert after the commit copies nothing.
#[test]
fn a_reservation_unshares_a_published_map_so_the_insert_after_the_commit_allocates_nothing() {
    let mut table = RouteTable::<u32, u32>::new();
    table.try_reserve(8).unwrap();
    let published = table.shared();
    table.try_reserve(1).unwrap();
    let reserved = Arc::as_ptr(&table.0);
    table.insert(1, 1);
    assert_eq!(Arc::as_ptr(&table.0), reserved, "the insert after the commit copied the map");
    assert!(published.is_empty(), "the published snapshot changed");
}
