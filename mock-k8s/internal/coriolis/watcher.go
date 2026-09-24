// Package coriolis restarts Deep Desert servers after each Coriolis cycle
// boundary (issue #119).
//
// Dune applies a new Coriolis cycle only when a server BOOTS: the seed and
// cycle dates are read at startup, and the map wipe runs in the database
// function coriolis_update_seed, which each server calls for its own map. A
// Deep Desert that is up across the boundary therefore keeps the old layout
// until someone restarts it. Our test server's log of the 2026-06-02 cycle
// shows it: the storm ran, 05:00 UTC passed with the server up and nothing
// logged, and only the 07:32 boot printed
//
//	LogCoriolis: Display: Current Coriolis World Seed: 3
//	LogCoriolis: Display: This Coriolis Cycle start date UTC: 2026.06.02-05.00.00
//
// Funcom's battlegroup operator restarts servers on a schedule; mock-k8s
// replaces that operator, so this watcher does the one restart the cycle
// needs. It reads the boundary from each instance's own boot line
//
//	LogCoriolis: Display: Next Coriolis Cycle start date UTC: 2026.06.02-05.00.00
//
// rather than hard-coding "Tuesday 05:00", so it follows whatever cycle the
// game computes.
package coriolis

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Sergentval/pelican-egg-dune-awakening/mock-k8s/internal/spawner"
)

const (
	nextCycleMarker = "Next Coriolis Cycle start date UTC: "
	cycleLayout     = "2006.01.02-15.04.05"

	// retryCooldown spaces out attempts on one instance after a failed
	// recycle, so a server that refuses to stop is not hammered every tick.
	retryCooldown = 30 * time.Minute
	// staggerBound is how long the next recycle waits for the previous
	// replacement to come back before giving up on it. A Deep Desert boot
	// takes about 40 s; this only has to be generous, not tight.
	staggerBound = 15 * time.Minute
)

// Recycler is the spawner side: list a map's instances, restart one in place.
type Recycler interface {
	InstancesOf(mapName string) []spawner.InstanceRef
	Recycle(key, suffix string) error
}

// Watcher recycles instances of the configured maps once their Coriolis
// boundary has passed.
type Watcher struct {
	rec     Recycler
	baseDir string
	maps    []string
	delay   time.Duration
	now     func() time.Time

	tails     map[string]*tail     // by log path
	acted     map[string]time.Time // log path -> boundary already recycled for
	attempted map[string]time.Time // log path -> last recycle attempt
	warned    map[string]bool      // log path -> "no cycle line" already logged

	// waitKey is the ServerSetScale whose replacement the next recycle waits
	// for, so several Deep Desert instances restart one at a time.
	waitKey   string
	waitSince time.Time
}

// New builds a watcher. delay is how long after the boundary to act: the
// storm's own end-of-cycle handling runs at the boundary, and restarting in
// the same second would race it.
func New(rec Recycler, baseDir string, maps []string, delay time.Duration) *Watcher {
	return &Watcher{
		rec:       rec,
		baseDir:   baseDir,
		maps:      append([]string(nil), maps...),
		delay:     delay,
		now:       time.Now,
		tails:     map[string]*tail{},
		acted:     map[string]time.Time{},
		attempted: map[string]time.Time{},
		warned:    map[string]bool{},
	}
}

// Run ticks until stop closes. interval <= 0 disables the watcher.
func (w *Watcher) Run(stop <-chan struct{}, interval time.Duration) {
	if interval <= 0 {
		slog.Info("coriolis: recycle watcher disabled")
		return
	}
	slog.Info("coriolis: recycle watcher started", "interval", interval, "delay", w.delay, "maps", w.maps)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			w.Tick()
		}
	}
}

type candidate struct {
	mapName string
	ref     spawner.InstanceRef
}

// Tick recycles at most one instance whose boundary has passed. Never returns
// an error: it runs beside a live server, and one bad poll must not stop the
// next.
func (w *Watcher) Tick() {
	now := w.now()
	var cands []candidate
	for _, m := range w.maps {
		for _, ref := range w.rec.InstancesOf(m) {
			cands = append(cands, candidate{mapName: m, ref: ref})
		}
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].ref.Key != cands[j].ref.Key {
			return cands[i].ref.Key < cands[j].ref.Key
		}
		return cands[i].ref.Suffix < cands[j].ref.Suffix
	})

	// Keep every tail current, even for instances we will not act on this
	// tick, so a fresh boot's line is never mistaken for an old one later.
	for _, c := range cands {
		w.tailFor(w.logPath(c.mapName, c.ref.Suffix)).refresh()
	}

	if w.waitingForReplacement(now, cands) {
		return
	}
	for _, c := range cands {
		if w.maybeRecycle(now, c) {
			return
		}
	}
}

// waitingForReplacement reports whether the previous recycle's replacement is
// still booting (and within staggerBound).
func (w *Watcher) waitingForReplacement(now time.Time, cands []candidate) bool {
	if w.waitKey == "" {
		return false
	}
	for _, c := range cands {
		if c.ref.Key == w.waitKey && c.ref.PID > 0 {
			w.waitKey = ""
			return false
		}
	}
	if now.Sub(w.waitSince) > staggerBound {
		slog.Warn("coriolis: recycled instance has not come back; moving on",
			"key", w.waitKey, "waited", now.Sub(w.waitSince).Round(time.Second))
		w.waitKey = ""
		return false
	}
	return true
}

// maybeRecycle recycles c if its boundary has passed and it has not been
// recycled for that boundary yet. Reports whether it attempted a recycle.
func (w *Watcher) maybeRecycle(now time.Time, c candidate) bool {
	path := w.logPath(c.mapName, c.ref.Suffix)
	// An instance without a pid is still booting, and its log may still end
	// with the PREVIOUS boot's lines. Only a running server is judged.
	if c.ref.PID <= 0 {
		return false
	}
	next := w.tails[path].next
	if next.IsZero() {
		if !w.warned[path] {
			w.warned[path] = true
			slog.Warn("coriolis: no cycle line in this instance's log; it will not be recycled at the boundary",
				"key", c.ref.Key, "suffix", c.ref.Suffix, "log", path)
		}
		return false
	}
	if now.Before(next.Add(w.delay)) || w.acted[path].Equal(next) {
		return false
	}
	if last, ok := w.attempted[path]; ok && now.Sub(last) < retryCooldown {
		return false
	}

	w.attempted[path] = now
	slog.Info("coriolis: cycle boundary passed while the server was up; restarting it to apply the new cycle",
		"map", c.mapName, "key", c.ref.Key, "suffix", c.ref.Suffix, "pid", c.ref.PID, "boundary", next.Format(time.RFC3339))
	if err := w.rec.Recycle(c.ref.Key, c.ref.Suffix); err != nil {
		slog.Warn("coriolis: recycle failed; will retry later",
			"key", c.ref.Key, "suffix", c.ref.Suffix, "retry_after", retryCooldown, "err", err)
		return true
	}
	w.acted[path] = next
	w.waitKey = c.ref.Key
	w.waitSince = now
	return true
}

func (w *Watcher) logPath(mapName, suffix string) string {
	return filepath.Join(w.baseDir, "logs", "ue5-"+mapName+"-"+suffix+".log")
}

func (w *Watcher) tailFor(path string) *tail {
	t, ok := w.tails[path]
	if !ok {
		t = &tail{path: path}
		w.tails[path] = t
	}
	return t
}

// tail follows one UE5 log and remembers the last Coriolis boundary it printed.
type tail struct {
	path    string
	offset  int64
	next    time.Time
	lastErr string
}

// refresh scans new lines and logs a read error once per distinct error.
func (t *tail) refresh() {
	if _, err := t.scan(); err != nil {
		if msg := err.Error(); msg != t.lastErr {
			t.lastErr = msg
			slog.Warn("coriolis: cannot read instance log", "log", t.path, "err", err)
		}
		return
	}
	t.lastErr = ""
}

// scan reads the lines appended since the last scan and reports whether a new
// boundary was seen. A file that SHRANK was trimmed in place by
// rotate-logs.sh: it is re-read from the start, but the boundary already known
// is kept, because the trim may have removed the only line that carried it. A
// missing file is not an error; the instance may not have logged yet. A final
// line without its newline is still being written and is left for next time.
func (t *tail) scan() (bool, error) {
	f, err := os.Open(t.path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return false, err
	}
	if info.Size() < t.offset {
		t.offset = 0
	}
	if info.Size() == t.offset {
		return false, nil
	}
	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return false, err
	}

	marker := []byte(nextCycleMarker)
	r := bufio.NewReaderSize(f, 64*1024)
	updated := false
	for {
		line, err := r.ReadBytes('\n')
		if errors.Is(err, io.EOF) {
			return updated, nil // any partial line stays unread
		}
		if err != nil {
			return updated, err
		}
		t.offset += int64(len(line))
		if !bytes.Contains(line, marker) {
			continue
		}
		if ts, ok := parseNextCycle(string(line)); ok {
			t.next = ts
			updated = true
		}
	}
}

// parseNextCycle extracts the boundary from a "Next Coriolis Cycle start
// date UTC" line. The game prints it in UTC.
func parseNextCycle(line string) (time.Time, bool) {
	i := strings.Index(line, nextCycleMarker)
	if i < 0 {
		return time.Time{}, false
	}
	ts, err := time.ParseInLocation(cycleLayout, strings.TrimSpace(line[i+len(nextCycleMarker):]), time.UTC)
	if err != nil {
		return time.Time{}, false
	}
	return ts, true
}
