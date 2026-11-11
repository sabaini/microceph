package ceph

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/canonical/microceph/microceph/api/types"
	"github.com/canonical/microceph/microceph/constants"
	"github.com/canonical/microceph/microceph/logger"
)

// FlashStore is the OSD of croit ceph-rust (https://github.com/croit/ceph-rust):
// croit-flashstore-osd replaces ceph-osd + BlueStore and croit-flashstore-tool
// replaces `ceph-osd --mkfs`. Monitors, managers and clients stay classic Ceph.

const (
	// osdBackendEnv selects the OSD implementation microcephd deploys.
	osdBackendEnv = "MICROCEPH_OSD_BACKEND"
	// osdBackendFlashStore is the osdBackendEnv value for croit-flashstore-osd.
	osdBackendFlashStore = "flashstore"

	flashStoreDaemon = "croit-flashstore-osd"
	flashStoreTool   = "croit-flashstore-tool"

	// flashStoreAdminEntity registers new OSDs. Its key is in the admin keyring
	// (constants.CephAdminKeyringFileName), which every cluster member has;
	// ceph.client.admin.keyring exists on the bootstrap member only.
	flashStoreAdminEntity = "client.admin"

	// Snap options (`snap set microceph <key>=<value>`) read at prepare time;
	// the osd service reads flashStoreCoresKey itself at start.
	flashStoreCoresKey    = "flashstore.cores"
	flashStoreAllowVWCKey = "flashstore.allow-vwc"
)

// useFlashStore reports whether OSDs are croit-flashstore-osd instead of ceph-osd.
func useFlashStore() bool {
	return os.Getenv(osdBackendEnv) == osdBackendFlashStore
}

// osdProcessPattern returns the pkill/pgrep -f pattern matching the process of
// osd.N. Both ceph-osd and croit-flashstore-osd are started with `--id N` last.
func osdProcessPattern(osd int64) string {
	daemon := "ceph-osd"
	if useFlashStore() {
		daemon = flashStoreDaemon
	}
	return fmt.Sprintf("%s .* --id %d$", daemon, osd)
}

// validateFlashStoreAdd refuses disk layouts FlashStore cannot serve: it owns
// one whole NVMe namespace per OSD and has no separate WAL/DB devices, no
// dm-crypt support and (in production builds) no file backed devices.
func validateFlashStoreAdd(data types.DiskParameter, wal *types.DiskParameter, db *types.DiskParameter) error {
	if isLoopDevice(data) {
		return fmt.Errorf("loop file OSDs are not supported with FlashStore: it needs a whole NVMe namespace")
	}
	if wal != nil || db != nil {
		return fmt.Errorf("WAL/DB devices are not supported with FlashStore")
	}
	if data.Encrypt {
		return fmt.Errorf("encryption is not supported with FlashStore: it cannot run on a dm-crypt device")
	}
	return nil
}

// flashStoreOptionArgs turns the flashstore.* snap options into prepare flags.
// cores is the per-OSD core count (store shards are sized from it), allowVWC
// admits devices with a volatile write cache (lab only: no power-loss protection).
func flashStoreOptionArgs(cores string, allowVWC string) ([]string, error) {
	args := []string{}

	cores = strings.TrimSpace(cores)
	if cores != "" {
		n, err := strconv.Atoi(cores)
		if err != nil || n < 1 {
			return nil, fmt.Errorf("invalid %s %q: expected a positive integer", flashStoreCoresKey, cores)
		}
		args = append(args, "--cores", strconv.Itoa(n))
	}

	allowVWC = strings.TrimSpace(allowVWC)
	if allowVWC != "" {
		allow, err := strconv.ParseBool(allowVWC)
		if err != nil {
			return nil, fmt.Errorf("invalid %s %q: expected true or false", flashStoreAllowVWCKey, allowVWC)
		}
		if allow {
			args = append(args, "--allow-vwc")
		}
	}

	return args, nil
}

// flashStorePrepareArgs builds the `croit-flashstore-tool prepare` command line
// for osd.N on the device at path. The tool formats the store, registers the
// OSD and its cephx key with the monitors and writes the OSD directory.
func flashStorePrepareArgs(nr int64, path string, wipe bool, confPath string, dataPath string, extra []string) []string {
	args := []string{
		"prepare",
		"--dev", "kernel:" + path,
		"--id", strconv.FormatInt(nr, 10),
		"--cluster", "ceph",
		"--conf", filepath.Join(confPath, constants.CephConfFileName),
		"--keyring", filepath.Join(confPath, constants.CephAdminKeyringFileName),
		"--entity", flashStoreAdminEntity,
		"--osd-data-root", filepath.Join(dataPath, "osd"),
	}
	if wipe {
		args = append(args, "--wipe")
	}
	return append(args, extra...)
}

// snapOption returns the value of a snap option, empty if it is unset.
func (m *OSDManager) snapOption(key string) (string, error) {
	out, err := m.runner.RunCommand("snapctl", "get", key)
	if err != nil {
		return "", fmt.Errorf("failed to read snap option %s: %w", key, err)
	}
	return strings.TrimSpace(out), nil
}

// bootstrapFlashStoreOSD prepares the FlashStore OSD nr on the data device.
func (m *OSDManager) bootstrapFlashStoreOSD(osdDataPath string, nr int64, data types.DiskParameter) error {
	logger.Infof("Bootstrapping FlashStore OSD %s to %d on %s", osdDataPath, nr, data.Path)

	cores, err := m.snapOption(flashStoreCoresKey)
	if err != nil {
		return err
	}
	allowVWC, err := m.snapOption(flashStoreAllowVWCKey)
	if err != nil {
		return err
	}
	extra, err := flashStoreOptionArgs(cores, allowVWC)
	if err != nil {
		return err
	}

	pathConsts := constants.GetPathConst()
	args := flashStorePrepareArgs(nr, data.Path, data.Wipe, pathConsts.ConfPath, pathConsts.DataPath, extra)
	_, err = m.runner.RunCommand(flashStoreTool, args...)
	if err != nil {
		return fmt.Errorf("failed to prepare FlashStore OSD: %w", err)
	}

	// prepare writes the ready marker last; without it the osd service skips the OSD.
	_, err = m.fs.Stat(osdReadyMarkerPath(osdDataPath))
	if err != nil {
		return fmt.Errorf("FlashStore OSD %d is not ready after prepare: %w", nr, err)
	}
	logger.Infof("FlashStore OSD %s bootstrapped successfully", osdDataPath)
	return nil
}
