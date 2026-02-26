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
