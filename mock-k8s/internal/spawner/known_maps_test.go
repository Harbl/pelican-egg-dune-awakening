package spawner

import (
	"testing"

	"github.com/Sergentval/pelican-egg-dune-awakening/mock-k8s/internal/serversetscale"
)

// The panel's scale control could only act on maps that already had a
// ServerSetScale, which meant the hub maps — the ones an operator most wants
// to start by hand — answered "not tracked by mock-k8s". They are not missing:
// the store holds a lazy-create recipe for every map in the BattleGroup
// template (35 of them on a stock 1.5 world) and materialises one on the first
// by-name GET. The panel simply had no way to learn the canonical name to ask
// for, because /status only ever listed what had already been materialised.
//
// knownMaps closes that gap: /status now also carries the recipes, so the
// panel can turn "SH_Arrakeen" into the name to GET, let the store create the
// record, and scale it — instead of telling the operator to go and stand in
// the map first.
func TestSnapshot_KnownMapsExposesLazyCreateRecipes(t *testing.T) {
	spw, _, store, _ := newTestSpawner(t)
	store.LazyCreator = &serversetscale.LazyCreator{
		WorldName: "sh-test",
		Maps: map[string]serversetscale.LazyMapInfo{
			"sh-test-sh-arrakeen":     {MapName: "SH_Arrakeen", PartitionID: 3, Replicas: 0},
			"sh-test-sh-harkovillage": {MapName: "SH_HarkoVillage", PartitionID: 4, Replicas: 0},
		},
	}

	snap := spw.Snapshot()

	byMap := map[string]string{}
	for _, km := range snap.KnownMaps {
		byMap[km.Map] = km.Name
	}
	if got := byMap["SH_Arrakeen"]; got != "sh-test-sh-arrakeen" {
		t.Errorf("SH_Arrakeen canonical name = %q, want sh-test-sh-arrakeen", got)
	}
	if got := byMap["SH_HarkoVillage"]; got != "sh-test-sh-harkovillage" {
		t.Errorf("SH_HarkoVillage canonical name = %q, want sh-test-sh-harkovillage", got)
	}
}

// Sorted output: the panel renders this list, and a map order that reshuffles
// every poll would make the UI jitter for no reason.
func TestSnapshot_KnownMapsIsSorted(t *testing.T) {
	spw, _, store, _ := newTestSpawner(t)
	store.LazyCreator = &serversetscale.LazyCreator{
		WorldName: "sh-test",
		Maps: map[string]serversetscale.LazyMapInfo{
			"sh-test-zulu":  {MapName: "Zulu", PartitionID: 9},
			"sh-test-alpha": {MapName: "Alpha", PartitionID: 1},
			"sh-test-mike":  {MapName: "Mike", PartitionID: 5},
		},
	}
	for i := 0; i < 20; i++ {
		snap := spw.Snapshot()
		if len(snap.KnownMaps) != 3 {
			t.Fatalf("knownMaps length = %d, want 3", len(snap.KnownMaps))
		}
		if snap.KnownMaps[0].Name != "sh-test-alpha" ||
			snap.KnownMaps[1].Name != "sh-test-mike" ||
			snap.KnownMaps[2].Name != "sh-test-zulu" {
			t.Fatalf("knownMaps not sorted on pass %d: %+v", i, snap.KnownMaps)
		}
	}
}

// No recipes (no template loaded) must yield an empty list, not a crash: the
// snapshot is what the panel polls, and it has to survive an early boot.
func TestSnapshot_KnownMapsEmptyWithoutLazyCreator(t *testing.T) {
	spw, _, _, _ := newTestSpawner(t)
	if n := len(spw.Snapshot().KnownMaps); n != 0 {
		t.Errorf("knownMaps = %d entries without a LazyCreator, want 0", n)
	}
}
