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
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"go.uber.org/zap"
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
//
// Unlike the original in-memory-only guard, this value is persisted to
// <archiveDir>/.last_reset_date after every successful reset and reloaded at
// process startup (see loadLastResetDate / saveLastResetDate). Persisting it
// closes two failure windows:
//   - A restart shortly AFTER a successful reset no longer re-triggers the
//     reset (the guard survives the restart).
//   - A restart ON the reset day but before the reset fired no longer loses
//     the month: the reloaded guard still shows the previous month, so the
//     next periodic check re-fires the reset as a catch-up.
//
// If the guard file is missing (first deployment ever, or a config change
// that moved archiveDir), the first check initialises it to today without
// performing a reset, preserving the original guarantee that a restart never
// accidentally clears historical data.
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
// so that cumulative counts survive process restarts, and restores the
// persisted last-reset-date guard from archiveDir so that restarting on the
// reset day can neither skip nor duplicate a monthly reset.
// Errors are silently ignored (missing file, parse error, etc.).
func loadTrafficStats(path string, archiveDir string) {
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

	lastResetDateMu.Lock()
	lastResetDate = loadLastResetDate(archiveDir)
	lastResetDateMu.Unlock()
}

// writeTrafficStats snapshots the in-memory counters and atomically writes
// them to outputPath as JSON (write to .tmp then rename, so readers never see
// a half-written file). It is used both by the periodic writer and immediately
// after a scheduled reset, so the zeroed state reaches disk right away instead
// of waiting for the next ticker.
func writeTrafficStats(outputPath string) error {
	snapshot := make(map[string]int64)
	trafficStats.Range(func(k, v interface{}) bool {
		snapshot[k.(string)] = atomic.LoadInt64(v.(*int64))
		return true
	})
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}
	tmpPath := outputPath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmpPath, outputPath)
}

// loadLastResetDate reads the persisted reset-date guard from
// <archiveDir>/.last_reset_date. Returns "" if the file is missing or unreadable.
func loadLastResetDate(archiveDir string) string {
	if archiveDir == "" {
		return ""
	}
	data, err := os.ReadFile(archiveDir + "/.last_reset_date")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// saveLastResetDate persists the reset-date guard to <archiveDir>/.last_reset_date
// using the same atomic write pattern (tmp file + rename) as traffic_by_user.json.
// Failures are deliberately non-fatal: the in-memory guard still protects the
// current process, and a missing guard file can only ever defer a reset, never
// lose data.
func saveLastResetDate(archiveDir, date string) {
	if archiveDir == "" {
		return
	}
	if err := os.MkdirAll(archiveDir, 0755); err != nil {
		return
	}
	guardPath := archiveDir + "/.last_reset_date"
	tmpPath := guardPath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(date), 0644); err != nil {
		return
	}
	_ = os.Rename(tmpPath, guardPath)
}

// startTrafficStatsWriter launches a background goroutine that periodically
// writes a snapshot of trafficStats to outputPath as JSON.
// It uses atomic-write (write to .tmp then rename) to avoid readers
// seeing a half-written file.
//
// If resetDay is in [1,28], the goroutine also checks whether today is the
// configured reset day and, if so, archives the current snapshot to archiveDir
// before zeroing the in-memory counters.
func startTrafficStatsWriter(outputPath string, interval time.Duration, resetDay int, archiveDir string, logger *zap.Logger) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			// Scheduled reset check (before writing, so the snapshot written
			// this tick is already post-reset).
			if resetDay > 0 {
				checkAndPerformScheduledReset(resetDay, archiveDir, outputPath, logger)
			}
			if err := writeTrafficStats(outputPath); err != nil {
				logger.Error("failed to write traffic stats",
					zap.String("path", outputPath), zap.Error(err))
				continue
			}
		}
	}()
}

// checkAndPerformScheduledReset checks whether today is the configured reset
// day and, if so, archives the current traffic snapshot and zeros the counters.
//
// Safety guarantees:
//   - On first run (no persisted guard, e.g. first deployment ever),
//     lastResetDate is initialised to today without performing a reset,
//     so a restart never accidentally clears historical data.
//   - If today is not the configured reset day, nothing happens.
//   - If the reset has already been performed today (lastResetDate == today),
//     nothing happens, preventing duplicate resets within the same day.
//   - If archiving fails (disk full, permissions, ...), the counters are NOT
//     zeroed and the guard is not advanced, so the next check retries instead
//     of losing data.
//   - After zeroing, the zeroed state is written to disk immediately (not
//     deferred to the next ticker), and the guard date is persisted, so
//     neither a crash nor a kill in the following window can resurrect the
//     pre-reset totals on next boot.
func checkAndPerformScheduledReset(resetDay int, archiveDir, statsPath string, logger *zap.Logger) {
	now := time.Now()
	today := now.Format("2006-01-02")

	lastResetDateMu.Lock()
	defer lastResetDateMu.Unlock()

	// First run after process start with no persisted guard: record today as
	// the last reset date without performing a reset. This prevents a restart
	// from accidentally clearing accumulated data.
	if lastResetDate == "" {
		lastResetDate = today
		saveLastResetDate(archiveDir, today)
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

	// Snapshot current counters (also used to roll back if persisting fails).
	snapshot := make(map[string]int64)
	trafficStats.Range(func(k, v interface{}) bool {
		snapshot[k.(string)] = atomic.LoadInt64(v.(*int64))
		return true
	})

	// Archive current counters first. If this fails, abort WITHOUT zeroing:
	// losing an archive copy is acceptable, losing the data is not.
	if err := os.MkdirAll(archiveDir, 0755); err != nil {
		logger.Error("traffic reset aborted: cannot create archive dir",
			zap.String("dir", archiveDir), zap.Error(err))
		return
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		logger.Error("traffic reset aborted: cannot marshal snapshot", zap.Error(err))
		return
	}
	archivePath := archiveDir + "/traffic_" + today + ".json"
	if err := os.WriteFile(archivePath, data, 0644); err != nil {
		logger.Error("traffic reset aborted: cannot write archive file",
			zap.String("path", archivePath), zap.Error(err))
		return
	}

	// Zero in-memory counters (users added concurrently after the snapshot
	// are left untouched, since they were not part of the archived data).
	trafficStats.Range(func(k, v interface{}) bool {
		if _, ok := snapshot[k.(string)]; ok {
			atomic.StoreInt64(v.(*int64), 0)
		}
		return true
	})

	// Persist the zeroed state immediately instead of waiting for the next
	// ticker: a kill in between (crash, OOM, SIGKILL during shutdown) would
	// otherwise resurrect the pre-reset totals on next boot.
	if err := writeTrafficStats(statsPath); err != nil {
		logger.Error("traffic reset: archive written but failed to persist zeroed stats; rolling back counters",
			zap.String("path", statsPath), zap.Error(err))
		// Roll back the in-memory counters so memory and disk stay consistent.
		// The guard is not advanced, so the next check will retry the reset.
		trafficStats.Range(func(k, v interface{}) bool {
			if val, ok := snapshot[k.(string)]; ok {
				atomic.StoreInt64(v.(*int64), val)
			}
			return true
		})
		return
	}

	// Persist the guard so a same-day restart cannot re-trigger the reset,
	// and a restart on the reset day (before this point) will catch up.
	saveLastResetDate(archiveDir, today)
	lastResetDate = today
}
