package main

import (
	"testing"

	"github.com/canonical/microceph/microceph/api/types"
	"github.com/stretchr/testify/assert"
)

func TestDiskAddValidateFlags(t *testing.T) {
	tests := []struct {
		name        string
		cmd         cmdDiskAdd
		args        []string
		expectError string
	}{
		{
			name: "valid osd-only match mode",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
			},
		},
		{
			name: "wal-match requires osd-match",
			cmd: cmdDiskAdd{
				flagWALMatch: "eq(@type, 'nvme')",
				flagWALSize:  "4GiB",
			},
			expectError: "--osd-match is required",
		},
		{
			name: "wal-match requires wal-size",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				flagWALMatch: "eq(@type, 'nvme')",
			},
			expectError: "--wal-size is required",
		},
		{
			name: "db-size requires db-match",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				flagDBSize:   "8GiB",
			},
			expectError: "--db-size requires --db-match",
		},
		{
			name: "match mode cannot use positional args",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
			},
			args:        []string{"/dev/sdb"},
			expectError: "cannot be used with positional",
		},
		{
			name: "match mode cannot combine with all-available",
			cmd: cmdDiskAdd{
				flagOSDMatch:   "eq(@type, 'ssd')",
				flagAllDevices: true,
			},
			expectError: "cannot be used with --all-available",
		},
		{
			name: "match mode cannot combine with wal-device",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				walDevice:    "/dev/nvme0n1",
			},
			expectError: "--wal-device and --db-device cannot be used",
		},
		{
			name: "match mode cannot combine with wal-wipe",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				walWipe:      true,
			},
			expectError: "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used",
		},
		{
			name: "match mode cannot combine with db-encrypt",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				dbEncrypt:    true,
			},
			expectError: "--wal-wipe/--wal-encrypt/--db-wipe/--db-encrypt cannot be used",
		},
		{
			name: "wal-wipe requires wal-device outside match mode",
			cmd: cmdDiskAdd{
				walWipe: true,
			},
			expectError: "--wal-wipe/--wal-encrypt require --wal-device",
		},
		{
			name: "db-encrypt requires db-device outside match mode",
			cmd: cmdDiskAdd{
				dbEncrypt: true,
			},
			expectError: "--db-wipe/--db-encrypt require --db-device",
		},
		{
			name: "valid osd wal db match mode",
			cmd: cmdDiskAdd{
				flagOSDMatch: "eq(@type, 'ssd')",
				flagWALMatch: "eq(@type, 'nvme')",
				flagWALSize:  "4GiB",
				flagDBMatch:  "eq(@vendor, 'samsung')",
				flagDBSize:   "20GiB",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cmd.validateFlags(tt.args)
			if tt.expectError == "" {
				assert.NoError(t, err)
				return
			}

			assert.Error(t, err)
			assert.Contains(t, err.Error(), tt.expectError)
		})
	}
}

func TestPrintDryRunOutputFailsOnValidationError(t *testing.T) {
	cmd := cmdDiskAdd{}

	err := cmd.printDryRunOutput(types.DiskAddResponse{ValidationError: "invalid DSL expression"})
	if assert.Error(t, err) {
		assert.Contains(t, err.Error(), "invalid DSL expression")
	}
}

func TestPrintAddDiskFailuresUsesReportErrorWhenReportsExist(t *testing.T) {
	resp := types.DiskAddResponse{
		ValidationError: "validation failed",
		Reports: []types.DiskAddReport{{
			Path:   "/dev/sdb",
			Report: "Failure",
			Error:  "partition create failed",
		}},
	}

	err := printAddDiskFailures(resp)
	if assert.Error(t, err) {
		assert.Contains(t, err.Error(), "partition create failed")
	}
}

func TestPrintAddDiskFailuresReturnsValidationErrorWhenNoReports(t *testing.T) {
	resp := types.DiskAddResponse{ValidationError: "invalid payload"}

	err := printAddDiskFailures(resp)
	if assert.Error(t, err) {
		assert.Contains(t, err.Error(), "invalid payload")
	}
}

func TestPrintAddDiskFailuresUsesFallbackForEmptySingleFailureError(t *testing.T) {
	resp := types.DiskAddResponse{
		Reports: []types.DiskAddReport{{
			Path:   "/dev/sdb",
			Report: "Failure",
			Error:  "",
		}},
	}

	err := printAddDiskFailures(resp)
	if assert.Error(t, err) {
		assert.Contains(t, err.Error(), "disk add failed")
	}
}
