package ceph

import (
	"context"
	"testing"

	"github.com/canonical/lxd/shared/api"
	"github.com/canonical/microceph/microceph/api/types"
	"github.com/canonical/microceph/microceph/database"
	"github.com/canonical/microceph/microceph/mocks"
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
