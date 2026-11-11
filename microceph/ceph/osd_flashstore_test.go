package ceph

import (
	"fmt"
	"path/filepath"

	"github.com/spf13/afero"
	"github.com/stretchr/testify/assert"

	"github.com/canonical/microceph/microceph/api/types"
	"github.com/canonical/microceph/microceph/constants"
	"github.com/canonical/microceph/microceph/mocks"
)

// TestUseFlashStore tests the OSD backend selection from the environment.
func (s *osdSuite) TestUseFlashStore() {
	s.T().Setenv(osdBackendEnv, "")
	assert.False(s.T(), useFlashStore())
	assert.Equal(s.T(), "ceph-osd .* --id 3$", osdProcessPattern(3))

	s.T().Setenv(osdBackendEnv, "bluestore")
	assert.False(s.T(), useFlashStore())

	s.T().Setenv(osdBackendEnv, osdBackendFlashStore)
	assert.True(s.T(), useFlashStore())
	assert.Equal(s.T(), "croit-flashstore-osd .* --id 3$", osdProcessPattern(3))
}

// TestValidateFlashStoreAdd tests that unsupported disk layouts are refused.
func (s *osdSuite) TestValidateFlashStoreAdd() {
	nvme := types.DiskParameter{Path: "/dev/disk/by-id/nvme-a"}
	aux := &types.DiskParameter{Path: "/dev/disk/by-id/nvme-b"}

	assert.NoError(s.T(), validateFlashStoreAdd(nvme, nil, nil))
	assert.NoError(s.T(), validateFlashStoreAdd(types.DiskParameter{Path: nvme.Path, Wipe: true}, nil, nil))

	assert.ErrorContains(s.T(), validateFlashStoreAdd(types.DiskParameter{LoopSize: 4096}, nil, nil), "loop file OSDs")
	assert.ErrorContains(s.T(), validateFlashStoreAdd(types.DiskParameter{Path: "loop,4G,1"}, nil, nil), "loop file OSDs")
	assert.ErrorContains(s.T(), validateFlashStoreAdd(nvme, aux, nil), "WAL/DB")
	assert.ErrorContains(s.T(), validateFlashStoreAdd(nvme, nil, aux), "WAL/DB")
	assert.ErrorContains(s.T(), validateFlashStoreAdd(types.DiskParameter{Path: nvme.Path, Encrypt: true}, nil, nil), "encryption")
}

// TestFlashStoreOptionArgs tests the mapping of flashstore.* snap options to prepare flags.
func (s *osdSuite) TestFlashStoreOptionArgs() {
	args, err := flashStoreOptionArgs("", "")
	assert.NoError(s.T(), err)
	assert.Empty(s.T(), args)

	args, err = flashStoreOptionArgs(" 2\n", "true")
	assert.NoError(s.T(), err)
	assert.Equal(s.T(), []string{"--cores", "2", "--allow-vwc"}, args)

	args, err = flashStoreOptionArgs("4", "false")
	assert.NoError(s.T(), err)
	assert.Equal(s.T(), []string{"--cores", "4"}, args)

	for _, cores := range []string{"0", "-1", "two", "2 --wipe"} {
		_, err = flashStoreOptionArgs(cores, "")
		assert.ErrorContains(s.T(), err, flashStoreCoresKey, cores)
	}

	_, err = flashStoreOptionArgs("", "maybe")
	assert.ErrorContains(s.T(), err, flashStoreAllowVWCKey)
}

// TestFlashStorePrepareArgs tests the prepare command line.
func (s *osdSuite) TestFlashStorePrepareArgs() {
	args := flashStorePrepareArgs(7, "/dev/disk/by-id/nvme-a", false, "/conf", "/data", nil)
	assert.Equal(s.T(), []string{
		"prepare",
		"--dev", "kernel:/dev/disk/by-id/nvme-a",
		"--id", "7",
		"--cluster", "ceph",
		"--conf", "/conf/ceph.conf",
		"--keyring", "/conf/ceph.keyring",
		"--entity", "client.admin",
		"--osd-data-root", "/data/osd",
	}, args)

	args = flashStorePrepareArgs(7, "/dev/nvme0n1", true, "/conf", "/data", []string{"--cores", "2"})
	assert.Equal(s.T(), []string{"--wipe", "--cores", "2"}, args[len(args)-3:])
}

// TestBootstrapFlashStoreOSD tests that prepare runs with the snap options applied.
func (s *osdSuite) TestBootstrapFlashStoreOSD() {
	osdmgr := NewOSDManager(nil)
	r := mocks.NewRunner(s.T())
	osdmgr.runner = r
	osdmgr.fs = afero.NewMemMapFs()

	pathConsts := constants.GetPathConst()
	osdDataPath := filepath.Join(pathConsts.DataPath, "osd", "ceph-4")
	data := types.DiskParameter{Path: "/dev/disk/by-id/nvme-a", Wipe: true}
	prepare := []interface{}{flashStoreTool}
	for _, arg := range flashStorePrepareArgs(4, data.Path, true, pathConsts.ConfPath, pathConsts.DataPath, []string{"--cores", "2", "--allow-vwc"}) {
		prepare = append(prepare, arg)
	}

	// prepare succeeds and leaves the ready marker
	r.On("RunCommand", "snapctl", "get", flashStoreCoresKey).Return("2\n", nil).Once()
	r.On("RunCommand", "snapctl", "get", flashStoreAllowVWCKey).Return("true\n", nil).Once()
	r.On("RunCommand", prepare...).Return("", nil).Once()
	err := afero.WriteFile(osdmgr.fs, osdReadyMarkerPath(osdDataPath), []byte("ready\n"), 0644)
	assert.NoError(s.T(), err)
	err = osdmgr.bootstrapFlashStoreOSD(osdDataPath, 4, data)
	assert.NoError(s.T(), err)

	// prepare fails: the tool's refusal is passed on
	r.On("RunCommand", "snapctl", "get", flashStoreCoresKey).Return("2", nil).Once()
	r.On("RunCommand", "snapctl", "get", flashStoreAllowVWCKey).Return("true", nil).Once()
	r.On("RunCommand", prepare...).Return("", fmt.Errorf("refused: device is not empty")).Once()
	err = osdmgr.bootstrapFlashStoreOSD(osdDataPath, 4, data)
	assert.ErrorContains(s.T(), err, "failed to prepare FlashStore OSD")
	assert.ErrorContains(s.T(), err, "device is not empty")

	// an invalid snap option stops before the device is touched
	r.On("RunCommand", "snapctl", "get", flashStoreCoresKey).Return("lots", nil).Once()
	r.On("RunCommand", "snapctl", "get", flashStoreAllowVWCKey).Return("", nil).Once()
	err = osdmgr.bootstrapFlashStoreOSD(osdDataPath, 4, data)
	assert.ErrorContains(s.T(), err, flashStoreCoresKey)

	// prepare reports success without a ready marker
	missing := filepath.Join(pathConsts.DataPath, "osd", "ceph-5")
	prepare5 := []interface{}{flashStoreTool}
	for _, arg := range flashStorePrepareArgs(5, data.Path, true, pathConsts.ConfPath, pathConsts.DataPath, []string{}) {
		prepare5 = append(prepare5, arg)
	}
	r.On("RunCommand", "snapctl", "get", flashStoreCoresKey).Return("", nil).Once()
	r.On("RunCommand", "snapctl", "get", flashStoreAllowVWCKey).Return("", nil).Once()
	r.On("RunCommand", prepare5...).Return("", nil).Once()
	err = osdmgr.bootstrapFlashStoreOSD(missing, 5, data)
	assert.ErrorContains(s.T(), err, "not ready after prepare")
}

// TestKillFlashStoreOSD tests that removal targets the croit-flashstore-osd process.
func (s *osdSuite) TestKillFlashStoreOSD() {
	s.T().Setenv(osdBackendEnv, osdBackendFlashStore)
	osdmgr := NewOSDManager(nil)
	r := mocks.NewRunner(s.T())
	osdmgr.runner = r

	r.On("RunCommand", "pkill", "-f", "croit-flashstore-osd .* --id 0$").Return("", nil).Once()
	r.On("RunCommand", "pgrep", "-f", "croit-flashstore-osd .* --id 0$").Return("", createExitError(s.T(), 1)).Once()
	err := osdmgr.killOSD(0)
	assert.NoError(s.T(), err)
}
