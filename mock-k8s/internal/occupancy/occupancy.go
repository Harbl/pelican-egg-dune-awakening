// Package occupancy answers one question: how many players are on each map
// right now.
//
// It asks scripts/admin-publish.sh, which reads dune.farm_state — the socket
// count every running instance heartbeats — and NOT dune.actors. The
// difference is load-bearing and was learned the hard way: actors groups a
// character by their PERSISTENT home map, so a player visiting Arrakeen still
// counts under the map they came from. A drain guard reading that sees the hub
// as empty and evicts the visitor. farm_state counts who is actually connected
// to a map's instances, which is the only count safe to reap on.
//
// The query is read-only and already exists; this package is the Go side of
// the same signal the Python autoscaler uses.
package occupancy

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ParseCounts reads the `map,players` CSV that admin-publish emits.
//
// A header row, blank lines and CRLF are tolerated, and a row whose count is
// not a non-negative integer is skipped rather than guessed at — a psql notice
// leaking into stdout must not become a player count of zero, which is the one
// value that gets an instance killed.
func ParseCounts(csvText string) map[string]int {
	counts := map[string]int{}
	for _, line := range strings.Split(csvText, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Map names contain no commas; split off the trailing count field.
		i := strings.LastIndex(line, ",")
		if i < 0 {
			continue
		}
		name := strings.TrimSpace(line[:i])
		raw := strings.TrimSpace(line[i+1:])
		if name == "" || strings.EqualFold(name, "map") {
			continue // header row
		}
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 {
			continue
		}
		counts[name] = n
	}
	return counts
}

// Reader runs admin-publish and parses what it prints.
type Reader struct {
	baseDir string
	timeout time.Duration
}

func NewReader(baseDir string) *Reader {
	return &Reader{baseDir: baseDir, timeout: 15 * time.Second}
}

// PlayerCounts returns the live per-map connected-player count.
//
// An error means "unknown", never "empty". Callers must hold rather than act:
// a failed query that read as zero everywhere would reap every instance on the
// server at once.
func (r *Reader) PlayerCounts() (map[string]int, error) {
	script := filepath.Join(r.baseDir, "scripts", "admin-publish.sh")
	ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", script, "farm-player-count")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("admin-publish farm-player-count: %w", err)
	}
	counts := ParseCounts(string(out))
	if len(counts) == 0 && strings.TrimSpace(string(out)) != "" {
		// Output we could not make sense of at all. Unknown, not empty.
		return nil, fmt.Errorf("admin-publish farm-player-count: no parseable rows")
	}
	return counts, nil
}
