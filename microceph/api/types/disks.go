// Package types provides shared types and structs.
package types

// DisksPost hold a path and a flag for enabling device wiping
type DisksPost struct {
	Path       []string `json:"path" yaml:"path"`
	Wipe       bool     `json:"wipe" yaml:"wipe"`
	Encrypt    bool     `json:"encrypt" yaml:"encrypt"`
	WALDev     *string  `json:"waldev" yaml:"waldev"`
	WALWipe    bool     `json:"walwipe" yaml:"walwipe"`
	WALEncrypt bool     `json:"walencrypt" yaml:"walencrypt"`
	DBDev      *string  `json:"dbdev" yaml:"dbdev"`
	DBWipe     bool     `json:"dbwipe" yaml:"dbwipe"`
	DBEncrypt  bool     `json:"dbencrypt" yaml:"dbencrypt"`
	// OSDMatch is a DSL expression for matching devices to use as OSDs.
	// When set, Path is ignored and devices are selected based on the expression.
	OSDMatch string `json:"osd_match,omitempty" yaml:"osd_match,omitempty"`
	// WALMatch is a DSL expression for matching backing devices used for WAL partitions.
	WALMatch string `json:"wal_match,omitempty" yaml:"wal_match,omitempty"`
	// DBMatch is a DSL expression for matching backing devices used for DB partitions.
	DBMatch string `json:"db_match,omitempty" yaml:"db_match,omitempty"`
	// WALSize is the requested WAL partition size (e.g. 4GiB).
	WALSize string `json:"wal_size,omitempty" yaml:"wal_size,omitempty"`
	// DBSize is the requested DB partition size (e.g. 20GiB).
	DBSize string `json:"db_size,omitempty" yaml:"db_size,omitempty"`
	// DryRun when true causes the command to report which devices would be
	// added without actually adding them. Only valid when OSDMatch is set.
	DryRun bool `json:"dry_run,omitempty" yaml:"dry_run,omitempty"`
}

// DiskAddReport holds report for single disk addition i.e. success/failure and optional error for failures.
type DiskAddReport struct {
	Path   string `json:"path" yaml:"path"`
	Report string `json:"report" yaml:"report"`
	Error  string `json:"error" yaml:"error"`
}

// DiskAddResponse holds response data for disk addition.
type DiskAddResponse struct {
	ValidationError string          `json:"validation_error" yaml:"validation_error"`
	Reports         []DiskAddReport `json:"report" yaml:"report"`
	// DryRunDevices contains the list of data devices that would be added
	// when dry_run is true. Only populated for DSL-based requests.
	DryRunDevices []DryRunDevice `json:"dry_run_devices,omitempty" yaml:"dry_run_devices,omitempty"`
	// DryRunWALDevices contains matched WAL backing block devices in dry-run mode.
	DryRunWALDevices []DryRunDevice `json:"dry_run_wal_devices,omitempty" yaml:"dry_run_wal_devices,omitempty"`
	// DryRunDBDevices contains matched DB backing block devices in dry-run mode.
	DryRunDBDevices []DryRunDevice `json:"dry_run_db_devices,omitempty" yaml:"dry_run_db_devices,omitempty"`
	// DryRunPartitions contains planned partition creation operations in dry-run mode.
	DryRunPartitions []DryRunPartition `json:"dry_run_partitions,omitempty" yaml:"dry_run_partitions,omitempty"`
	// DryRunAssignments maps each planned OSD to planned WAL/DB partition paths.
	DryRunAssignments []DryRunAssignment `json:"dry_run_assignments,omitempty" yaml:"dry_run_assignments,omitempty"`
}

// DryRunDevice represents a device that would be added during a dry run.
type DryRunDevice struct {
	Path   string `json:"path" yaml:"path"`
	Model  string `json:"model" yaml:"model"`
	Size   string `json:"size" yaml:"size"`
	Type   string `json:"type" yaml:"type"`
	Vendor string `json:"vendor" yaml:"vendor"`
}

// DryRunPartition describes a partition that would be created.
type DryRunPartition struct {
	Role      string `json:"role" yaml:"role"`
	DiskPath  string `json:"disk_path" yaml:"disk_path"`
	PartNum   uint64 `json:"part_num" yaml:"part_num"`
	PartPath  string `json:"part_path" yaml:"part_path"`
	PartSize  string `json:"part_size" yaml:"part_size"`
	ForOSDIdx int    `json:"for_osd_idx" yaml:"for_osd_idx"`
}

// DryRunAssignment describes planned WAL/DB devices for a given OSD data device.
type DryRunAssignment struct {
	OSDDevice string `json:"osd_device" yaml:"osd_device"`
	WALDevice string `json:"wal_device,omitempty" yaml:"wal_device,omitempty"`
	DBDevice  string `json:"db_device,omitempty" yaml:"db_device,omitempty"`
}

// DisksDelete holds an OSD number and a flag for forcing the removal
type DisksDelete struct {
	OSD                    int64 `json:"osdid" yaml:"osdid"`
	BypassSafety           bool  `json:"bypass_safety" yaml:"bypass_safety"`
	ConfirmDowngrade       bool  `json:"confirm_downgrade" yaml:"confirm_downgrade"`
	ProhibitCrushScaledown bool  `json:"prohibit_crush_scaledown" yaml:"prohibit_crush_scaledown"`
	Timeout                int64 `json:"timeout" yaml:"timeout"`
}

// Disks is a slice of disks
type Disks []Disk

// Disk holds data for a device: OSD number, it's path and a location
type Disk struct {
	OSD      int64  `json:"osd" yaml:"osd"`
	Path     string `json:"path" yaml:"path"`
	Location string `json:"location" yaml:"location"`
}

type DiskParameter struct {
	Path     string
	Encrypt  bool
	Wipe     bool
	LoopSize uint64
}
