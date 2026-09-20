package serversetscale

import "testing"

// The Director keys its ServerSetScale dictionary by an ANNOTATION, not a label.
// Decompiled from BattlegroupUtils.dll (Director 1.5, build 25351779):
//
//	foreach (ServerSetScale item in val.Items)
//	    dictionary.Add(ModelExtensions.GetAnnotation(item, "igw.funcom.com/map-name"), item);
//
// We only ever set that key under metadata.labels, so GetAnnotation returned
// null and Dictionary.Add threw:
//
//	System.ArgumentNullException: Value cannot be null. (Parameter 'key')
//	   at BattlegroupUtils.Igwo.Api.ListServerSetScales(Int32 timeoutSeconds)
//
// which killed the Director at startup. That single crash is why LIST has
// returned an empty set since May: the workaround cost every player the
// ability to travel to a hub or a mission instance, because the Director never
// learns an instance exists and the travel request sits in the queue until
// TravelRequestExpirationTimeSeconds (300s) expires — the "In Queue" wait a
// reporter measured at five minutes.
const dirMapNameKey = "igw.funcom.com/map-name"

func TestLazyCreate_SetsTheAnnotationTheDirectorReads(t *testing.T) {
	s := NewStore()
	s.LazyCreator = &LazyCreator{WorldName: "sh-test", Maps: map[string]LazyMapInfo{
		"sh-test-survival-1": {MapName: "Survival_1", PartitionID: 1, Replicas: 1},
	}}
	obj, ok := s.GetOrLazyCreate("default", "sh-test-survival-1")
	if !ok {
		t.Fatal("lazy-create failed")
	}
	if got := obj.Metadata.Annotations[dirMapNameKey]; got != "Survival_1" {
		t.Errorf("annotation %s = %q, want Survival_1 — the Director keys its dictionary on this and crashes on a null", dirMapNameKey, got)
	}
	// The label stays: it costs nothing and other tooling may select on it.
	if got := obj.Metadata.Labels[dirMapNameKey]; got != "Survival_1" {
		t.Errorf("label %s = %q, want Survival_1", dirMapNameKey, got)
	}
}

func TestEnsureUniformItem_DerivesTheAnnotationFromSpec(t *testing.T) {
	// An object stored without metadata at all — what a bare Create leaves
	// behind — must still gain the annotation before it reaches a LIST.
	o := Object{
		Metadata: Metadata{Name: "sh-test-overmap", Namespace: "default"},
		Spec:     map[string]any{"mapName": "Overmap", "replicas": int64(1)},
	}
	got := ensureUniformItem(o)
	if v := got.Metadata.Annotations[dirMapNameKey]; v != "Overmap" {
		t.Errorf("annotation %s = %q, want Overmap", dirMapNameKey, v)
	}
}

func TestEnsureUniformItem_KeepsAnExistingAnnotation(t *testing.T) {
	o := Object{
		Metadata: Metadata{
			Name:        "sh-test-x",
			Annotations: map[string]string{dirMapNameKey: "AlreadySet"},
		},
		Spec: map[string]any{"mapName": "Overmap"},
	}
	if v := ensureUniformItem(o).Metadata.Annotations[dirMapNameKey]; v != "AlreadySet" {
		t.Errorf("annotation was overwritten: %q", v)
	}
}

func TestEnsureUniformItem_DoesNotMutateTheStoredObject(t *testing.T) {
	// The same trap the labels map already documents: the item handed to a
	// LIST is a copy, so deriving fields must never write through to the store.
	o := Object{
		Metadata: Metadata{Name: "sh-test-y"},
		Spec:     map[string]any{"mapName": "Overmap"},
	}
	_ = ensureUniformItem(o)
	if o.Metadata.Annotations != nil {
		t.Error("ensureUniformItem wrote annotations back onto its argument")
	}
}

// No mapName means no key the Director could use. Inventing one would hand it a
// dictionary entry pointing at the wrong map, which is worse than the item
// being absent: better to leave the annotation unset and let that item be the
// one it complains about.
func TestEnsureUniformItem_NoMapNameLeavesTheAnnotationUnset(t *testing.T) {
	o := Object{Metadata: Metadata{Name: "sh-test-z"}, Spec: map[string]any{"replicas": int64(1)}}
	if v, has := ensureUniformItem(o).Metadata.Annotations[dirMapNameKey]; has {
		t.Errorf("annotation invented from nothing: %q", v)
	}
}
