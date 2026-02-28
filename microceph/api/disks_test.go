package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/tidwall/gjson"
)

func TestCmdDisksPostRejectsMatchFieldsWithoutOSDMatch(t *testing.T) {
	reqBody := `{"path":[],"wal_match":"eq(@type, 'nvme')","wal_size":"4GiB"}`
	req := httptest.NewRequest(http.MethodPost, "/1.0/disks", strings.NewReader(reqBody))

	resp := cmdDisksPost(nil, req)
	rr := httptest.NewRecorder()
	err := resp.Render(rr, req)
	assert.NoError(t, err)

	validationError := gjson.Get(rr.Body.String(), "metadata.validation_error").String()
	assert.NotEmpty(t, validationError)
	assert.Contains(t, validationError, "osd-match")
}

func TestCmdDisksPostRejectsRoleSpecificWalDbFlagsInMatchMode(t *testing.T) {
	reqBody := `{"path":[],"osd_match":"eq(@type, 'ssd')","dry_run":true,"walwipe":true}`
	req := httptest.NewRequest(http.MethodPost, "/1.0/disks", strings.NewReader(reqBody))

	resp := cmdDisksPost(nil, req)
	rr := httptest.NewRecorder()
	err := resp.Render(rr, req)
	assert.NoError(t, err)

	validationError := gjson.Get(rr.Body.String(), "metadata.validation_error").String()
	assert.NotEmpty(t, validationError)
	assert.Contains(t, validationError, "--wal-wipe")
}
