package ceph

import (
	"testing"

	"github.com/canonical/lxd/shared/api"
	"github.com/stretchr/testify/assert"
)

func TestPlanRolePartitionsEvenDistribution(t *testing.T) {
	disks := []api.ResourcesStorageDisk{
		{
			ID:       "sdb",
			DeviceID: "disk-a",
			Size:     100 * 1024 * 1024 * 1024,
		},
		{
			ID:       "sdc",
			DeviceID: "disk-b",
			Size:     100 * 1024 * 1024 * 1024,
		},
	}

	plan, err := planRolePartitions("wal", disks, 10*1024*1024*1024, 6, false)
	assert.NoError(t, err)
	assert.Len(t, plan, 6)

	countByDisk := map[string]int{}
	for _, p := range plan {
		countByDisk[p.DiskPath]++
	}

	assert.Equal(t, 3, countByDisk["/dev/disk/by-id/disk-a"])
	assert.Equal(t, 3, countByDisk["/dev/disk/by-id/disk-b"])
}

func TestPlanRolePartitionsInsufficientCapacity(t *testing.T) {
	disks := []api.ResourcesStorageDisk{
		{
			ID:       "sdb",
			DeviceID: "disk-a",
			Size:     20 * 1024 * 1024 * 1024,
		},
	}

	plan, err := planRolePartitions("db", disks, 10*1024*1024*1024, 3, false)
	assert.Error(t, err)
	assert.Nil(t, plan)
	assert.Contains(t, err.Error(), "insufficient db capacity")
}

func TestValidateNoDiskOverlap(t *testing.T) {
	osdDisks := []api.ResourcesStorageDisk{{ID: "sdb", DeviceID: "disk-a"}}
	walDisks := []api.ResourcesStorageDisk{{ID: "sdc", DeviceID: "disk-b"}}
	dbDisks := []api.ResourcesStorageDisk{{ID: "sdb", DeviceID: "disk-a"}}

	err := validateNoDiskOverlap(osdDisks, walDisks, dbDisks)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "overlap")
}

func TestPlanRolePartitionsWipeIgnoresExistingPartitions(t *testing.T) {
	disks := []api.ResourcesStorageDisk{
		{
			ID:       "sdb",
			DeviceID: "disk-a",
			Size:     100 * 1024 * 1024 * 1024,
			Partitions: []api.ResourcesStorageDiskPartition{
				{Partition: 1, Size: 40 * 1024 * 1024 * 1024},
				{Partition: 2, Size: 40 * 1024 * 1024 * 1024},
			},
		},
	}

	// Without wipe only 20GiB is free, so 3x10GiB cannot fit.
	plan, err := planRolePartitions("wal", disks, 10*1024*1024*1024, 3, false)
	assert.Error(t, err)
	assert.Nil(t, plan)

	// With wipe enabled planner should assume full disk capacity and restart partition numbers from 1.
	plan, err = planRolePartitions("wal", disks, 10*1024*1024*1024, 3, true)
	assert.NoError(t, err)
	assert.Len(t, plan, 3)
	assert.Equal(t, uint64(1), plan[0].PartNum)
}

func TestHasMountedPartitions(t *testing.T) {
	disk := api.ResourcesStorageDisk{
		Partitions: []api.ResourcesStorageDiskPartition{{Partition: 1, Mounted: false}},
	}
	assert.False(t, hasMountedPartitions(disk))

	disk.Partitions = append(disk.Partitions, api.ResourcesStorageDiskPartition{Partition: 2, Mounted: true})
	assert.True(t, hasMountedPartitions(disk))
}
