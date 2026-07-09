// Copyright 2024 forwardproxy contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package forwardproxy

import (
	"fmt"
	"strconv"
	"strings"
)

// parseByteSize parses a human-friendly byte size string and returns the
// number of bytes as int64. Supported formats:
//   - Plain number: "1024" → 1024
//   - With unit (case-insensitive): "1KB", "50MB", "10GB", "1TB", "500B"
//   - Unit may have optional space: "50 GB"
//
// Returns an error for negative values, overflow, or unrecognised units.
func parseByteSize(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty byte size")
	}

	// Try plain integer first.
	if v, err := strconv.ParseInt(s, 10, 64); err == nil {
		if v < 0 {
			return 0, fmt.Errorf("negative byte size: %d", v)
		}
		return v, nil
	}

	// Split into numeric prefix and unit suffix.
	s = strings.ToUpper(s)
	s = strings.TrimSpace(s)

	var unit string
	var numStr string

	units := []string{"TB", "GB", "MB", "KB", "B"}
	for _, u := range units {
		if strings.HasSuffix(s, u) {
			unit = u
			numStr = strings.TrimSpace(strings.TrimSuffix(s, u))
			break
		}
	}
	if unit == "" {
		return 0, fmt.Errorf("unrecognised byte size: %q (expected number with optional unit B/KB/MB/GB/TB)", s)
	}

	multiplier := int64(1)
	switch unit {
	case "TB":
		multiplier = 1 << 40
	case "GB":
		multiplier = 1 << 30
	case "MB":
		multiplier = 1 << 20
	case "KB":
		multiplier = 1 << 10
	case "B":
		multiplier = 1
	}

	val, err := strconv.ParseFloat(numStr, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid numeric value %q in byte size: %q", numStr, s)
	}
	if val < 0 {
		return 0, fmt.Errorf("negative byte size: %q", s)
	}

	result := int64(val * float64(multiplier))
	// Overflow check: if val >= 1 and result < multiplier, we wrapped.
	if val >= 1 && result < multiplier {
		return 0, fmt.Errorf("byte size overflow: %q", s)
	}
	return result, nil
}