// Copyright 2024 forwardproxy contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package forwardproxy

import (
	"encoding/json"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// contextKeyUsername is the context key for storing the authenticated
// proxy username, set in checkCredentials and read at dualStream call sites.
type contextKeyUsername struct{}

// trafficStats holds per-user cumulative byte counts.
// Key: username string, Value: *int64 (atomic-add compatible).
var trafficStats sync.Map

// trafficStatsOnce ensures the background writer goroutine is started only once,
// even if multiple Handler instances are provisioned.
var trafficStatsOnce sync.Once

// lastResetDate records the most recent date (in "2006-01-02" format) on which
// a scheduled traffic stats reset was performed. It prevents the same reset day
// from being triggered multiple times within the same 24-hour window.
// On process restart it is empty, and checkAndPerformScheduledReset initialises
// it to today — deliberately skipping a reset on the first run so that a
// restart never accidentally clears historical data.
var lastResetDate string
var lastResetDateMu sync.Mutex

// addTrafficForUser atomically adds bytes to the named user's cumulative counter.
// If username is empty, "unknown" is used as a fallback.
func addTrafficForUser(username string, bytes int64) {
	if username == "" {
		username = "unknown"
	}
	val, _ := trafficStats.LoadOrStore(username, new(int64))
	atomic.AddInt64(val.(*int64), bytes)
}

// loadTrafficStats reads an existing JSON stats file into trafficStats
// so that cumulative counts survive process restarts.
// Errors are silently ignored (missing file, parse error, etc.).
func loadTrafficStats(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return // file does not exist yet — normal on first run
	}
	var snapshot map[string]int64
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return
	}
	for user, total := range snapshot {
		ptr := new(int64)
		atomic.StoreInt64(ptr, total)
		trafficStats.Store(user, ptr)
	}
}

// startTrafficStatsWriter launches a background goroutine that periodically
// writes a snapshot of trafficStats to outputPath as JSON.
// It uses atomic-write (write to .tmp then rename) to avoid readers
// seeing a half-written file.
//
// If resetDay is in [1,28], the goroutine also checks whether today is the
// configured reset day and, if so, archives the current snapshot to archiveDir
// before zeroing the in-memory counters.
func startTrafficStatsWriter(outputPath string, interval time.Duration, resetDay int, archiveDir string) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			// Scheduled reset check (before writing, so the snapshot written
			// this tick is already post-reset).
			if resetDay > 0 {
				checkAndPerformScheduledReset(resetDay, archiveDir)
			}

			snapshot := make(map[string]int64)
			trafficStats.Range(func(k, v interface{}) bool {
				snapshot[k.(string)] = atomic.LoadInt64(v.(*int64))
				return true
			})
			data, err := json.MarshalIndent(snapshot, "", "  ")
			if err != nil {
				continue
			}
			tmpPath := outputPath + ".tmp"
			if err := os.WriteFile(tmpPath, data, 0644); err != nil {
				continue
			}
			_ = os.Rename(tmpPath, outputPath)
		}
	}()
}

// checkAndPerformScheduledReset checks whether today is the configured reset
// day and, if so, archives the current traffic snapshot and zeros the counters.
//
// Safety guarantees:
//   - On first call (or after a process restart), lastResetDate is empty and is
//     initialised to today without performing a reset. This ensures a restart
//     never accidentally zeroes data.
//   - If today is not the configured reset day, nothing happens.
//   - If the reset has already been performed today (lastResetDate == today),
//     nothing happens, preventing duplicate resets within the same day.
func checkAndPerformScheduledReset(resetDay int, archiveDir string) {
	now := time.Now()
	today := now.Format("2006-01-02")

	lastResetDateMu.Lock()
	defer lastResetDateMu.Unlock()

	// First run after process start: record today as the last reset date
	// without performing a reset. This prevents a restart from accidentally
	// clearing accumulated data.
	if lastResetDate == "" {
		lastResetDate = today
		return
	}

	// Not the configured reset day — nothing to do.
	if now.Day() != resetDay {
		return
	}

	// Already performed a reset today — skip to avoid duplicates.
	if lastResetDate == today {
		return
	}

	// --- Perform archive + reset ---

	// Snapshot current counters.
	snapshot := make(map[string]int64)
	trafficStats.Range(func(k, v interface{}) bool {
		snapshot[k.(string)] = atomic.LoadInt64(v.(*int64))
		return true
	})

	// Write archive file.
	_ = os.MkdirAll(archiveDir, 0755)
	archivePath := archiveDir + "/traffic_" + today + ".json"
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err == nil {
		_ = os.WriteFile(archivePath, data, 0644)
	}

	// Zero in-memory counters.
	trafficStats.Range(func(k, v interface{}) bool {
		atomic.StoreInt64(v.(*int64), 0)
		return true
	})

	lastResetDate = today
}