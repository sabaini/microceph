package types

import (
	"fmt"
	"strings"
)

const (
	ErrMatchRequiresOSDMatch        = "--osd-match is required when using --wal-match/--db-match/--wal-size/--db-size"
	ErrMatchWithPositionalArgs      = "--osd-match/--wal-match/--db-match cannot be used with positional device arguments"
	ErrDryRunRequiresOSDMatch       = "--dry-run requires --osd-match"
	ErrWALMatchRequiresWALSize      = "--wal-size is required when --wal-match is set"
	ErrDBMatchRequiresDBSize        = "--db-size is required when --db-match is set"
	ErrWALSizeRequiresWALMatch      = "--wal-size requires --wal-match"
	ErrDBSizeRequiresDBMatch        = "--db-size requires --db-match"
	ErrRoleDevicesNotAllowedInMatch = "--wal-device and --db-device cannot be used with --osd-match/--wal-match/--db-match"
	ErrRoleFlagsNotAllowedInMatch   = "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used with --osd-match/--wal-match/--db-match"
	ErrWALFlagsRequireWALDevice     = "--wal-wipe/--wal-encrypt require --wal-device"
	ErrDBFlagsRequireDBDevice       = "--db-wipe/--db-encrypt require --db-device"
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
		return fmt.Errorf(ErrMatchRequiresOSDMatch)
	}

	if isMatchMode && hasNonEmptyDiskPaths(req.Path) {
		return fmt.Errorf(ErrMatchWithPositionalArgs)
	}

	if req.DryRun && req.OSDMatch == "" {
		return fmt.Errorf(ErrDryRunRequiresOSDMatch)
	}

	if req.WALMatch != "" && req.WALSize == "" {
		return fmt.Errorf(ErrWALMatchRequiresWALSize)
	}

	if req.DBMatch != "" && req.DBSize == "" {
		return fmt.Errorf(ErrDBMatchRequiresDBSize)
	}

	if req.WALSize != "" && req.WALMatch == "" {
		return fmt.Errorf(ErrWALSizeRequiresWALMatch)
	}

	if req.DBSize != "" && req.DBMatch == "" {
		return fmt.Errorf(ErrDBSizeRequiresDBMatch)
	}

	if isMatchMode && ((req.WALDev != nil && strings.TrimSpace(*req.WALDev) != "") || (req.DBDev != nil && strings.TrimSpace(*req.DBDev) != "")) {
		return fmt.Errorf(ErrRoleDevicesNotAllowedInMatch)
	}

	if isMatchMode && (req.WALWipe || req.WALEncrypt || req.DBWipe || req.DBEncrypt) {
		return fmt.Errorf(ErrRoleFlagsNotAllowedInMatch)
	}

	if (req.WALWipe || req.WALEncrypt) && (req.WALDev == nil || strings.TrimSpace(*req.WALDev) == "") {
		return fmt.Errorf(ErrWALFlagsRequireWALDevice)
	}

	if (req.DBWipe || req.DBEncrypt) && (req.DBDev == nil || strings.TrimSpace(*req.DBDev) == "") {
		return fmt.Errorf(ErrDBFlagsRequireDBDevice)
	}

	return nil
}
