package spawner

import (
	"syscall"
	"testing"
	"time"

	"github.com/Sergentval/pelican-egg-dune-awakening/mock-k8s/internal/proc"
)

// The duplicate-partition crash loop of 2026-09-19.
//
// start-ue5.sh backgrounds UE5 and blocks on its UDP-bind handshake before
// writing the pidfile, so the pidfile appears only once the instance is really
// up. Deep Desert takes ~40s to get there (our own autoscaler config says so),
// while capturePID gave up after 20s. Giving up closes pidReady, which is what
// makes sweep() call the instance a "phantom": it reaped a UE5 that was still
// booting, released its port slot, and the next reconcile tick spawned a
// SECOND instance on the same partition.
//
// Two servers then claimed IGW index 8, and the incumbent died on it:
//
//	LogServerIndices: Warning: Server B connected with desired index 8, which
//	                  is already assigned to A, assuming this server has shut down
//	Fatal error: [S2sController.cpp:4497] Local partition is not found
//	SIGSEGV: invalid attempt to write memory at address 0x3
//
// which produced another reap, another spawn, another collision -- until the
// spawner gave up after 7 consecutive failures and parked Deep Desert at
// desired=0. A reporter's server sat there with no Deep Desert at all.
//
// The tell the spawner already had but ignored: the launcher process. While
// `bash start-ue5.sh` is alive, the instance is STARTING, not phantom.

// capturePID must not give up while the launcher it started is still running,
// however long the map takes to bind. Giving up is what manufactures the
// phantom.
func TestSpawner_CapturePIDWaitsWhileLauncherAlive(t *testing.T) {
	spw, pl, _, _ := newTestSpawner(t)
	spw.pidWait = 80 * time.Millisecond // stands in for the old 20s give-up
	spw.pidHardCap = 10 * time.Second

	alloc, _ := pl.Acquire()
	launcher := startSleeper(t) // stands in for start-ue5.sh still handshaking
	lstart, _ := proc.StartTime(launcher)

	ready := make(chan struct{})
	go spw.capturePID("default/deepdesert-1", alloc.Index,
		spw.pidPath("DeepDesert_1", "p"+itoa(alloc.Index)), ready, launcher, lstart)

	time.Sleep(10 * spw.pidWait) // well past the give-up window
	if isChanClosed(ready) {
		t.Fatal("capturePID gave up while start-ue5.sh was still running: the instance now looks phantom to sweep(), which reaps a booting UE5 and lets a second one spawn on the same partition")
	}
	_ = syscall.Kill(launcher, syscall.SIGKILL) // let the goroutine finish
}

// A pidfile that lands after the give-up window — the real Deep Desert case —
// must still be recorded, and the instance must survive the sweep.
func TestSpawner_SlowInstanceIsRecordedAndNotReaped(t *testing.T) {
	spw, pl, _, base := newTestSpawner(t)
	spw.pidWait = 80 * time.Millisecond
	spw.pidHardCap = 10 * time.Second

	const key = "default/deepdesert-1"
	alloc, _ := pl.Acquire()
	launcher := startSleeper(t)
	lstart, _ := proc.StartTime(launcher)
	ue5 := startSleeper(t) // the UE5 process that is slow to announce itself

	ready := make(chan struct{})
	inst := instance{
		Suffix: "p" + itoa(alloc.Index), MapName: "DeepDesert_1", PartitionID: 8,
		Allocation: alloc, pidReady: ready,
		launcherPID: launcher, launcherStart: lstart,
	}
	spw.mu.Lock()
	spw.instances[key] = []instance{inst}
	spw.mu.Unlock()

	go spw.capturePID(key, alloc.Index, spw.pidPath("DeepDesert_1", inst.Suffix), ready, launcher, lstart)

	// Mid-boot: past the old give-up window, pidfile not yet written.
	time.Sleep(5 * spw.pidWait)
	if reaped := spw.sweep(); len(reaped) != 0 {
		t.Fatalf("sweep reaped a still-booting instance: %v", reaped)
	}

	// UE5 finishes binding; start-ue5.sh writes the pidfile and exits.
	writePidfile(t, base, "DeepDesert_1", inst.Suffix, ue5)
	deadline := time.Now().Add(5 * time.Second)
	for !isChanClosed(ready) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !isChanClosed(ready) {
		t.Fatal("capturePID never finished after the pidfile appeared")
	}

	spw.mu.Lock()
	got := spw.instances[key]
	spw.mu.Unlock()
	if len(got) != 1 || got[0].PID != ue5 {
		t.Fatalf("slow instance did not get its pid recorded: %+v", got)
	}
	if reaped := spw.sweep(); len(reaped) != 0 {
		t.Fatalf("sweep reaped a live instance after its pid landed: %v", reaped)
	}
	_ = syscall.Kill(launcher, syscall.SIGKILL)
}

// The guard must not make a genuine failure un-reapable: launcher gone and no
// pidfile means the spawn really did fail, and the slot has to come back.
func TestSpawner_DeadLauncherWithoutPidfileStillGivesUp(t *testing.T) {
	spw, pl, _, _ := newTestSpawner(t)
	spw.pidWait = 80 * time.Millisecond
	spw.pidHardCap = 10 * time.Second

	const key = "default/deepdesert-1"
	alloc, _ := pl.Acquire()
	dead := deadPID(t)
	ready := make(chan struct{})
	spw.mu.Lock()
	spw.instances[key] = []instance{{
		Suffix: "p" + itoa(alloc.Index), MapName: "DeepDesert_1", PartitionID: 8,
		Allocation: alloc, pidReady: ready, launcherPID: dead, launcherStart: 1,
	}}
	spw.mu.Unlock()

	spw.capturePID(key, alloc.Index, spw.pidPath("DeepDesert_1", "p"+itoa(alloc.Index)), ready, dead, 1)
	if !isChanClosed(ready) {
		t.Fatal("capturePID kept waiting on a launcher that had already exited")
	}
	if reaped := spw.sweep(); !reaped[key] {
		t.Fatal("sweep did not reap a spawn whose launcher died without writing a pidfile")
	}
	if used, _, _ := pl.Stats(); used != 0 {
		t.Errorf("failed spawn left its slot reserved: used=%d, want 0", used)
	}
}

// A launcher that hangs forever must not hold a slot for ever either: the hard
// cap is the backstop that keeps the old give-up behaviour available.
func TestSpawner_HardCapEndsAnEndlessLauncherWait(t *testing.T) {
	spw, pl, _, _ := newTestSpawner(t)
	spw.pidWait = 20 * time.Millisecond
	spw.pidHardCap = 150 * time.Millisecond

	alloc, _ := pl.Acquire()
	launcher := startSleeper(t)
	lstart, _ := proc.StartTime(launcher)
	ready := make(chan struct{})

	done := make(chan struct{})
	go func() {
		spw.capturePID("default/deepdesert-1", alloc.Index,
			spw.pidPath("DeepDesert_1", "p"+itoa(alloc.Index)), ready, launcher, lstart)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("capturePID ignored its hard cap and waited on a hung launcher for ever")
	}
	_ = syscall.Kill(launcher, syscall.SIGKILL)
}
