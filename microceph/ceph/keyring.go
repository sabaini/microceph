package ceph

import (
	"bufio"
	"fmt"
	"github.com/canonical/microceph/microceph/common"
	"os"
	"strings"
)

func genKeyring(path, name string, caps ...[]string) error {
	args := []string{
		"--create-keyring",
		path,
		"--gen-key",
		"-n", name,
	}

	for _, capability := range caps {
		if len(capability) != 2 {
			return fmt.Errorf("Invalid keyring capability: %v", capability)
		}

		args = append(args, "--cap", capability[0], capability[1])
	}

	_, err := common.ProcessExec.RunCommand("ceph-authtool", args...)
	if err != nil {
		return err
	}

	return nil
}

func importKeyring(path string, source string) error {
	args := []string{
		path,
		"--import-keyring",
		source,
	}

	_, err := common.ProcessExec.RunCommand("ceph-authtool", args...)
	if err != nil {
		return err
	}

	return nil
}

func genAuth(path string, name string, caps ...[]string) error {
	args := []string{
		"auth",
		"get-or-create",
		name,
	}

	for _, capability := range caps {
		if len(capability) != 2 {
			return fmt.Errorf("Invalid keyring capability: %v", capability)
		}

		args = append(args, capability[0], capability[1])
	}

	args = append(args, "-o", path)

	_, err := cephRun(args...)
	if err != nil {
		return err
	}

	return nil
}

func parseKeyring(path string) (string, error) {
	// Open the CEPH keyring.
	cephKeyring, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("Failed to open %q: %w", path, err)
	}

	// Locate the keyring entry and its value.
	var cephSecret string
	scan := bufio.NewScanner(cephKeyring)
	for scan.Scan() {
		line := scan.Text()
		line = strings.TrimSpace(line)

		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "key") {
			fields := strings.SplitN(line, "=", 2)
			if len(fields) < 2 {
				continue
			}

			cephSecret = strings.TrimSpace(fields[1])
			break
		}
	}

	if cephSecret == "" {
		return "", fmt.Errorf("couldn't find a keyring entry")
	}

	return cephSecret, nil
}

// CreateClientKey creates a client key and returns the said key hash without saving it as a file.
func CreateClientKey(clientName string, caps ...[]string) (string, error) {
	args := []string{
		"auth",
		"get-or-create",
		fmt.Sprintf("client.%s", clientName),
	}

	// add caps to the key.
	for _, capability := range caps {
		if len(capability) != 2 {
			return "", fmt.Errorf("invalid keyring capability: %v", capability)
		}

		args = append(args, capability[0], capability[1])
	}

	_, err := cephRun(args...)
	if err != nil {
		return "", err
	}

	args = []string{
		"auth",
		"print-key",
		fmt.Sprintf("client.%s", clientName),
	}

	output, err := cephRun(args...)
	if err != nil {
		return "", err
	}

	return output, nil
}

func DeleteClientKey(clientName string) error {
	args := []string{
		"auth",
		"del",
		fmt.Sprintf("client.%s", clientName),
	}

	_, err := cephRun(args...)
	if err != nil {
		return err
	}

	return nil
}
