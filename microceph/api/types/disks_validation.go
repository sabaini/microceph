package types

import (
	"fmt"
	"strings"
)

// IsDisksPostMatchMode reports whether any DSL match-mode field is set.
func IsDisksPostMatchMode(req DisksPost) bool {
	return req.OSDMatch != "" || req.WALMatch != "" || req.DBMatch != "" || req.WALSize != "" || req.DBSize != ""
}

func hasNonEmptyDiskPaths(paths []string) bool {
	for _, path := range paths {
		if strings.TrimSpace(path) != "" {
			return true
		}
	}

	return false
}

// ValidateDisksPostMatchFields validates cross-field semantics for match mode.
//
// This is shared by API and CLI validation to avoid drift.
func ValidateDisksPostMatchFields(req DisksPost) error {
	isMatchMode := IsDisksPostMatchMode(req)

	if isMatchMode && req.OSDMatch == "" {
		return fmt.Errorf("--osd-match is required when using --wal-match/--db-match/--wal-size/--db-size")
	}

	if isMatchMode && hasNonEmptyDiskPaths(req.Path) {
		return fmt.Errorf("--osd-match/--wal-match/--db-match cannot be used with positional device arguments")
	}

	if req.DryRun && req.OSDMatch == "" {
		return fmt.Errorf("--dry-run requires --osd-match")
	}

	if req.WALMatch != "" && req.WALSize == "" {
		return fmt.Errorf("--wal-size is required when --wal-match is set")
	}

	if req.DBMatch != "" && req.DBSize == "" {
		return fmt.Errorf("--db-size is required when --db-match is set")
	}

	if req.WALSize != "" && req.WALMatch == "" {
		return fmt.Errorf("--wal-size requires --wal-match")
	}

	if req.DBSize != "" && req.DBMatch == "" {
		return fmt.Errorf("--db-size requires --db-match")
	}

	if isMatchMode && ((req.WALDev != nil && strings.TrimSpace(*req.WALDev) != "") || (req.DBDev != nil && strings.TrimSpace(*req.DBDev) != "")) {
		return fmt.Errorf("--wal-device and --db-device cannot be used with --osd-match/--wal-match/--db-match")
	}

	if isMatchMode && (req.WALWipe || req.WALEncrypt || req.DBWipe || req.DBEncrypt) {
		return fmt.Errorf("--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used with --osd-match/--wal-match/--db-match")
	}

	if (req.WALWipe || req.WALEncrypt) && (req.WALDev == nil || strings.TrimSpace(*req.WALDev) == "") {
		return fmt.Errorf("--wal-wipe/--wal-encrypt require --wal-device")
	}

	if (req.DBWipe || req.DBEncrypt) && (req.DBDev == nil || strings.TrimSpace(*req.DBDev) == "") {
		return fmt.Errorf("--db-wipe/--db-encrypt require --db-device")
	}

	return nil
}
