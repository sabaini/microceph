package ceph

import (
	"context"
	"fmt"
	"testing"

	"github.com/canonical/lxd/shared/api"
	"github.com/canonical/microceph/microceph/api/types"
	"github.com/canonical/microceph/microceph/database"
	"github.com/canonical/microceph/microceph/mocks"
	"github.com/spf13/afero"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

type staticPristineChecker struct {
	pristine bool
	err      error
}

func (s staticPristineChecker) IsPristineDisk(string) (bool, error) {
	return s.pristine, s.err
}

type staticPathValidator struct {
	isBlock bool
}

func (s staticPathValidator) IsBlockdevPath(string) bool {
	return s.isBlock
}

type staticFileStater struct {
	major uint32
	minor uint32
	err   error
}

func (s staticFileStater) GetFileStat(string) (uid int, gid int, major uint32, minor uint32, inode uint64, nlink int, err error) {
	if s.err != nil {
		return 0, 0, 0, 0, 0, 0, s.err
	}

	return 0, 0, s.major, s.minor, 0, 0, nil
}

func TestAddDisksWithDSLValidatesWALDSLWhenNoOSDsMatch(t *testing.T) {
	osdQuery := mocks.NewOSDQueryInterface(t)
	oldOSDQuery := database.OSDQuery
	database.OSDQuery = osdQuery
	t.Cleanup(func() {
		database.OSDQuery = oldOSDQuery
	})

	osdQuery.On("List", mock.Anything, mock.Anything).Return(types.Disks{}, nil).Once()

	storage := mocks.NewStorageInterface(t)
	storage.On("GetStorage").Return(&api.ResourcesStorage{Disks: []api.ResourcesStorageDisk{}}, nil).Once()

	mgr := NewOSDManager(nil)
	mgr.storage = storage

	resp := mgr.AddDisksWithDSL(
		context.Background(),
		"eq(@type, 'ssd')",
		"eq(@type",
		"",
		"4GiB",
		"",
		false,
		false,
		false,
	)

	assert.NotEmpty(t, resp.ValidationError)
	assert.Contains(t, resp.ValidationError, "invalid DSL expression")
}

func TestDiskEligibleForWALDBRejectsMixedClusterFSIDLabels(t *testing.T) {
	clusterFSID := "cluster-fsid"
	diskPath := "/dev/disk/by-id/disk-a"
	partPath := "/dev/disk/by-id/disk-a-part1"

	disk := api.ResourcesStorageDisk{
		ID:       "sda",
		DeviceID: "disk-a",
		Partitions: []api.ResourcesStorageDiskPartition{
			{Partition: 1},
		},
	}

	runner := mocks.NewRunner(t)
	runner.On("RunCommand", "ceph-bluestore-tool", "show-label", "--dev", diskPath).
		Return(`{"label":{"ceph_fsid":"cluster-fsid"}}`, nil).Once()
	runner.On("RunCommand", "ceph-bluestore-tool", "show-label", "--dev", partPath).
		Return(`{"label":{"ceph_fsid":"other-fsid"}}`, nil).Once()

	mgr := NewOSDManager(nil)
	mgr.runner = runner
	mgr.pristineChecker = staticPristineChecker{pristine: false, err: nil}

	eligible, err := mgr.diskEligibleForWALDB(disk, clusterFSID, false)
	assert.NoError(t, err)
	assert.False(t, eligible)
}

// Regression test: data-disk preflight failures (e.g. non-pristine data devices)
// must abort before any WAL/DB partition creation command is executed.
func TestApplyDSLPlannedDisksSkipsPartitionCreationOnDataPreflightFailure(t *testing.T) {
	mgr := NewOSDManager(nil)

	storage := mocks.NewStorageInterface(t)
	storage.On("GetStorage").Return(&api.ResourcesStorage{Disks: []api.ResourcesStorageDisk{{
		ID:       "sdb",
		Device:   "8:16",
		DeviceID: "osd-a",
		Size:     20 * 1024 * 1024 * 1024,
	}}}, nil).Once()
	mgr.storage = storage

	mgr.validator = staticPathValidator{isBlock: true}
	mgr.fileStater = staticFileStater{major: 8, minor: 16}
	mgr.pristineChecker = staticPristineChecker{pristine: false, err: nil}

	runner := mocks.NewRunner(t)
	mgr.runner = runner

	matchedOSDs := []api.ResourcesStorageDisk{{ID: "sdb", DeviceID: "osd-a", Device: "8:16"}}
	walPlan := []plannedPartition{{
		Role:      "wal",
		DiskPath:  "/dev/disk/by-id/wal-a",
		DiskID:    "sdc",
		DiskDev:   "8:32",
		PartNum:   1,
		PartPath:  "/dev/disk/by-id/wal-a-part1",
		PartSize:  1024 * 1024 * 1024,
		ForOSDIdx: 0,
	}}

	resp := mgr.applyDSLPlannedDisks(context.Background(), matchedOSDs, walPlan, nil, false, false, false)

	assert.NotEmpty(t, resp.ValidationError)
	assert.Contains(t, resp.ValidationError, "not pristine")
	assert.Empty(t, resp.Reports)
	assert.Empty(t, runner.Calls)
}

func TestApplyDSLPlannedDisksRollsBackCreatedPartitionsOnAddFailure(t *testing.T) {
	mgr := NewOSDManager(nil)
	mgr.fs = afero.NewMemMapFs()

	err := mgr.fs.MkdirAll("/dev", 0755)
	assert.NoError(t, err)
	err = afero.WriteFile(mgr.fs, "/dev/waldisk1", []byte{}, 0644)
	assert.NoError(t, err)
	err = afero.WriteFile(mgr.fs, "/dev/dbdisk1", []byte{}, 0644)
	assert.NoError(t, err)

	storage := mocks.NewStorageInterface(t)
	storage.On("GetStorage").Return(nil, fmt.Errorf("storage unavailable")).Maybe()
	mgr.storage = storage

	runner := mocks.NewRunner(t)
	runner.On("RunCommand", "sgdisk", "--new=1:0:+2", "--typecode=1:8300", "/dev/wal-disk").Return("", nil).Once()
	runner.On("RunCommand", "sgdisk", "--new=1:0:+2", "--typecode=1:8300", "/dev/db-disk").Return("", nil).Once()
	runner.On("RunCommand", "sgdisk", "--delete=1", "/dev/db-disk").Return("", nil).Once()
	runner.On("RunCommand", "sgdisk", "--delete=1", "/dev/wal-disk").Return("", nil).Once()
	mgr.runner = runner

	matchedOSDs := []api.ResourcesStorageDisk{{ID: "sdb", DeviceID: "osd-a", Device: "8:16"}}
	walPlan := []plannedPartition{{
		Role:      "wal",
		DiskPath:  "/dev/wal-disk",
		DiskID:    "waldisk",
		PartNum:   1,
		PartSize:  1024,
		ForOSDIdx: 0,
	}}
	dbPlan := []plannedPartition{{
		Role:      "db",
		DiskPath:  "/dev/db-disk",
		DiskID:    "dbdisk",
		PartNum:   1,
		PartSize:  1024,
		ForOSDIdx: 0,
	}}

	preflight := func([]api.ResourcesStorageDisk, bool, bool) error {
		return nil
	}
	addDisk := func(ctx context.Context, data types.DiskParameter, wal *types.DiskParameter, db *types.DiskParameter) types.DiskAddReport {
		return types.DiskAddReport{Path: data.Path, Report: "Failure", Error: "simulated add failure"}
	}

	resp := mgr.applyDSLPlannedDisksWithHooks(context.Background(), matchedOSDs, walPlan, dbPlan, false, false, false, preflight, addDisk)

	assert.Empty(t, resp.ValidationError)
	assert.Len(t, resp.Reports, 1)
	assert.Equal(t, "Failure", resp.Reports[0].Report)
}

func TestApplyDSLPlannedDisksPartitionFailureDoesNotHidePriorSuccess(t *testing.T) {
	mgr := NewOSDManager(nil)
	mgr.fs = afero.NewMemMapFs()

	err := mgr.fs.MkdirAll("/dev", 0755)
	assert.NoError(t, err)
	err = afero.WriteFile(mgr.fs, "/dev/waldisk1", []byte{}, 0644)
	assert.NoError(t, err)
	// No /dev/waldisk2 file needed because second create command is forced to fail.

	storage := mocks.NewStorageInterface(t)
	storage.On("GetStorage").Return(nil, fmt.Errorf("storage unavailable")).Maybe()
	mgr.storage = storage

	runner := mocks.NewRunner(t)
	runner.On("RunCommand", "sgdisk", "--new=1:0:+2", "--typecode=1:8300", "/dev/wal-disk").Return("", nil).Once()
	runner.On("RunCommand", "sgdisk", "--new=2:0:+2", "--typecode=2:8300", "/dev/wal-disk").Return("", fmt.Errorf("simulated partition create failure")).Once()
	mgr.runner = runner

	matchedOSDs := []api.ResourcesStorageDisk{
		{ID: "sdb", DeviceID: "osd-a", Device: "8:16"},
		{ID: "sdc", DeviceID: "osd-b", Device: "8:32"},
	}
	walPlan := []plannedPartition{
		{Role: "wal", DiskPath: "/dev/wal-disk", DiskID: "waldisk", PartNum: 1, PartSize: 1024, ForOSDIdx: 0},
		{Role: "wal", DiskPath: "/dev/wal-disk", DiskID: "waldisk", PartNum: 2, PartSize: 1024, ForOSDIdx: 1},
	}

	preflight := func([]api.ResourcesStorageDisk, bool, bool) error {
		return nil
	}
	addCalls := 0
	addDisk := func(ctx context.Context, data types.DiskParameter, wal *types.DiskParameter, db *types.DiskParameter) types.DiskAddReport {
		addCalls++
		return types.DiskAddReport{Path: data.Path, Report: "Success", Error: ""}
	}

	resp := mgr.applyDSLPlannedDisksWithHooks(context.Background(), matchedOSDs, walPlan, nil, false, false, false, preflight, addDisk)

	assert.Empty(t, resp.ValidationError)
	assert.Len(t, resp.Reports, 2)
	assert.Equal(t, "Success", resp.Reports[0].Report)
	assert.Equal(t, "Failure", resp.Reports[1].Report)
	assert.Contains(t, resp.Reports[1].Error, "failed creating wal partition")
	assert.Equal(t, 1, addCalls)
}
