package serversetscale

import "testing"

// Why every recipe is materialised at boot.
//
// The Director routes a player to a mission or hub instance by scaling that
// map's ServerSetScale. It only ever touches the ones it can see in LIST — on a
// reporter's server it GET/PATCHed exactly two names, sh-arrakeen and
// sh-harkovillage, because those were the only non-warm maps that had ever been
// materialised (he had added them to DUNE_ALWAYS_WARM_MAPS). Every mission map
// stayed a recipe nobody had asked for, so its travel queue read:
//
//	Processing travel queue for ClassicalInstancing group CB_Story_BanditFortress01 (servers: [], num: 0)
//
// forever, and the player's request died on schedule:
//
//	Travel request expired. MapName: CB_Story_BanditFortress01
//
// Materialising costs nothing at rest: a recipe that is not always-warm carries
// Replicas 0, so the record exists and no UE5 starts until the Director asks
// for one.

func lazyFixture() *LazyCreator {
	return &LazyCreator{WorldName: "sh-test", Maps: map[string]LazyMapInfo{
		"sh-test-survival-1":  {MapName: "Survival_1", PartitionID: 1, Replicas: 1},
		"sh-test-cb-bandit":   {MapName: "CB_Story_BanditFortress01", PartitionID: 27, Replicas: 0},
		"sh-test-cb-thepit":   {MapName: "CB_Dungeon_ThePit", PartitionID: 30, Replicas: 0},
		"sh-test-sh-arrakeen": {MapName: "SH_Arrakeen", PartitionID: 3, Replicas: 0},
	}}
}

func TestMaterializeAll_CreatesEveryRecipe(t *testing.T) {
	s := NewStore()
	s.LazyCreator = lazyFixture()
	if n := s.MaterializeAll("default"); n != 4 {
		t.Fatalf("materialised %d, want 4", n)
	}
	for name := range lazyFixture().Maps {
		if _, ok := s.Get("default", name); !ok {
			t.Errorf("%s was not materialised — the Director cannot scale what it cannot list", name)
		}
	}
}

// The whole point: a mission map exists as a record but starts nothing.
func TestMaterializeAll_KeepsNonWarmMapsAtZeroReplicas(t *testing.T) {
	s := NewStore()
	s.LazyCreator = lazyFixture()
	s.MaterializeAll("default")

	obj, _ := s.Get("default", "sh-test-cb-bandit")
	if r := readReplicasForTest(obj); r != 0 {
		t.Errorf("mission map materialised with replicas=%d — that would boot a UE5 per map at every start", r)
	}
	warm, _ := s.Get("default", "sh-test-survival-1")
	if r := readReplicasForTest(warm); r != 1 {
		t.Errorf("always-warm map lost its replicas: got %d, want 1", r)
	}
}

func TestMaterializeAll_IsIdempotent(t *testing.T) {
	s := NewStore()
	s.LazyCreator = lazyFixture()
	s.MaterializeAll("default")
	before := s.CurrentResourceVersion()
	if n := s.MaterializeAll("default"); n != 0 {
		t.Errorf("second pass created %d objects, want 0", n)
	}
	if after := s.CurrentResourceVersion(); after != before {
		t.Errorf("second pass bumped the resource version %s -> %s; every watcher would see a spurious event",
			before, after)
	}
}

// An operator-set scale must survive a later pass — materialising is a floor,
// never a reset.
func TestMaterializeAll_DoesNotOverwriteAnExistingObject(t *testing.T) {
	s := NewStore()
	s.LazyCreator = lazyFixture()
	s.MaterializeAll("default")
	obj, _ := s.Get("default", "sh-test-cb-bandit")
	obj.Spec["replicas"] = int64(2)
	if _, ok := s.Update(obj); !ok {
		t.Fatal("update failed")
	}
	s.MaterializeAll("default")
	again, _ := s.Get("default", "sh-test-cb-bandit")
	if r := readReplicasForTest(again); r != 2 {
		t.Errorf("materialise reset a live scale to %d, want 2", r)
	}
}

func TestMaterializeAll_NoLazyCreatorIsANoOp(t *testing.T) {
	s := NewStore()
	if n := s.MaterializeAll("default"); n != 0 {
		t.Errorf("materialised %d without a template, want 0", n)
	}
}

func readReplicasForTest(o Object) int64 {
	switch v := o.Spec["replicas"].(type) {
	case int64:
		return v
	case float64:
		return int64(v)
	}
	return -1
}
