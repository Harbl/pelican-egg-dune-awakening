package serversetscale

import "testing"

// Why ScaleUpTo exists rather than "Get, poke the spec, Update".
//
// Get returns the Object by value, but Spec is a map: the copy ALIASES the
// stored map. A caller that writes into it has already changed the stored
// object before Update is called — outside the lock, while HTTP handlers read
// it — and then Update's own change detection compares the map against
// itself, finds no difference, and skips OnSpecChange. The spawner never hears
// about the scale; it only notices later, when the reconcile loop sweeps.
//
// That is exactly the path a travel request takes, so the player waits for a
// sweep instead of for the spawn. ScaleUpTo does the read, the compare and the
// write under the one lock, the way Patch already did for the Director.

func scaleFixture(t *testing.T) (*Store, chan Object) {
	t.Helper()
	s := NewStore()
	s.LazyCreator = lazyFixture()
	s.MaterializeAll("default")
	events := make(chan Object, 4)
	s.OnSpecChange = func(o Object) { events <- o }
	return s, events
}

func TestScaleUpTo_FiresOnSpecChangeSoTheSpawnerActsImmediately(t *testing.T) {
	s, events := scaleFixture(t)
	_, changed, ok := s.ScaleUpTo("default", "sh-test-cb-bandit", 1)
	if !ok {
		t.Fatal("ScaleUpTo reported failure on a materialised map")
	}
	if !changed {
		t.Error("ScaleUpTo reported no change while raising 0 -> 1")
	}
	select {
	case got := <-events:
		if r := readReplicasForTest(got); r != 1 {
			t.Errorf("OnSpecChange saw replicas=%d, want 1", r)
		}
	default:
		t.Fatal("OnSpecChange never fired — the spawner would not start the map until the next reconcile sweep")
	}
	stored, _ := s.Get("default", "sh-test-cb-bandit")
	if r := readReplicasForTest(stored); r != 1 {
		t.Errorf("stored replicas=%d, want 1", r)
	}
}

// A second travel request to a map that is already up must not disturb it:
// no event, no resourceVersion bump, no restart.
func TestScaleUpTo_LeavesAnAlreadyRunningMapAlone(t *testing.T) {
	s, events := scaleFixture(t)
	s.ScaleUpTo("default", "sh-test-cb-bandit", 1)
	<-events
	before := s.CurrentResourceVersion()

	_, changed, ok := s.ScaleUpTo("default", "sh-test-cb-bandit", 1)
	if !ok {
		t.Fatal("second ScaleUpTo reported failure")
	}
	if changed {
		t.Error("a redundant scale reported changed=true; the watcher would log a start that never happened")
	}
	select {
	case got := <-events:
		t.Errorf("a redundant scale fired OnSpecChange with %v — that respawns a live instance", got.Spec)
	default:
	}
	if after := s.CurrentResourceVersion(); after != before {
		t.Errorf("redundant scale bumped the resource version %s -> %s", before, after)
	}
}

// Never scale DOWN: an always-warm map sits at 1, and a travel request to it
// must not be able to take it below what the operator asked for.
func TestScaleUpTo_NeverLowersAnExistingScale(t *testing.T) {
	s, events := scaleFixture(t)
	s.ScaleUpTo("default", "sh-test-cb-bandit", 3)
	<-events
	s.ScaleUpTo("default", "sh-test-cb-bandit", 1)
	stored, _ := s.Get("default", "sh-test-cb-bandit")
	if r := readReplicasForTest(stored); r != 3 {
		t.Errorf("replicas fell to %d, want 3 — ScaleUpTo is a floor, not an assignment", r)
	}
}

// The returned object must be the caller's to hold: writing into it must not
// reach into the store behind the lock.
func TestScaleUpTo_ReturnsASpecTheCallerCannotAliasIntoTheStore(t *testing.T) {
	s, _ := scaleFixture(t)
	got, _, _ := s.ScaleUpTo("default", "sh-test-cb-bandit", 1)
	got.Spec["replicas"] = int64(99)
	stored, _ := s.Get("default", "sh-test-cb-bandit")
	if r := readReplicasForTest(stored); r != 1 {
		t.Errorf("mutating the returned spec changed the store to %d — the map is shared", r)
	}
}

func TestScaleUpTo_UnknownObjectReturnsFalse(t *testing.T) {
	s, _ := scaleFixture(t)
	if _, _, ok := s.ScaleUpTo("default", "sh-test-does-not-exist", 1); ok {
		t.Error("ScaleUpTo invented an object it had no recipe for")
	}
}

// The footgun this method replaces, pinned so nobody reintroduces the pattern:
// Get hands back an aliased Spec, so a mutate-then-Update looks like a no-op.
func TestUpdate_WithAnAliasedSpecCannotDetectTheChange(t *testing.T) {
	s, events := scaleFixture(t)
	obj, _ := s.Get("default", "sh-test-cb-bandit")
	obj.Spec["replicas"] = int64(1) // writes straight into the stored map
	s.Update(obj)
	select {
	case <-events:
		t.Error("Update detected an aliased spec change; if this now works, the ScaleUpTo comment is stale")
	default:
	}
}
