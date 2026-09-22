package occupancy

import "testing"

func TestParseCounts_ReadsTheCSVAdminPublishEmits(t *testing.T) {
	got := ParseCounts("map,players\nSH_Arrakeen,3\nCB_Dungeon_ThePit,0\nSurvival_1,12\n")
	want := map[string]int{"SH_Arrakeen": 3, "CB_Dungeon_ThePit": 0, "Survival_1": 12}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %d, want %d", k, got[k], v)
		}
	}
}

func TestParseCounts_ToleratesBlankLinesAndCRLF(t *testing.T) {
	got := ParseCounts("map,players\r\n\r\nSH_Arrakeen,2\r\n\n")
	if len(got) != 1 || got["SH_Arrakeen"] != 2 {
		t.Errorf("got %v, want one row for SH_Arrakeen", got)
	}
}

// A zero is the one value that gets an instance killed, so anything we cannot
// read as a number is dropped rather than defaulted. A psql notice leaking
// into stdout must never become "nobody is on this map".
func TestParseCounts_SkipsRowsThatAreNotCounts(t *testing.T) {
	got := ParseCounts("map,players\nNOTICE: something,oops\nSH_Arrakeen,4\nBroken,-2\nNoComma\n")
	if len(got) != 1 || got["SH_Arrakeen"] != 4 {
		t.Errorf("got %v, want only the one readable row", got)
	}
}

func TestParseCounts_EmptyInputIsEmpty(t *testing.T) {
	if got := ParseCounts(""); len(got) != 0 {
		t.Errorf("got %v, want nothing", got)
	}
	if got := ParseCounts("map,players\n"); len(got) != 0 {
		t.Errorf("header alone gave %v, want nothing", got)
	}
}

// A map whose name legitimately contains no comma but whose count field is
// missing must not be read as zero.
func TestParseCounts_MissingCountIsNotZero(t *testing.T) {
	if got := ParseCounts("SH_Arrakeen,\n"); len(got) != 0 {
		t.Errorf("got %v, want nothing — an empty count is unknown, not zero", got)
	}
}
