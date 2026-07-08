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
func startTrafficStatsWriter(outputPath string, interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
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