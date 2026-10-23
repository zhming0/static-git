package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// Installation is deliberately separate from fallbackEnv: only the explicit
// helper may write outside the bundle, and it must leave existing stores alone.
func installSystemCA(bundle string) error {
	if len(os.Args) != 1 {
		return fmt.Errorf("usage: static-git-install-ca (no arguments)")
	}
	files := append([]string{
		"/etc/pki/tls/cacert.pem",
		"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
		"/etc/ca-certificates/extracted/tls-ca-bundle.pem",
	}, systemCAFiles...)
	for _, path := range files {
		// Even an empty file or dangling symlink belongs to the image.
		if _, err := os.Lstat(path); err == nil {
			fmt.Printf("Skipped: system CA store exists at %s\n", path)
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("cannot inspect system CA store %s: %w", path, err)
		}
	}
	for _, path := range []string{
		"/etc/ssl/certs",
		"/etc/pki/tls/certs",
		"/usr/local/share/certs",
		"/etc/openssl/certs",
	} {
		entries, err := os.ReadDir(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("cannot inspect system CA directory %s: %w", path, err)
		}
		// Do not try to decide which existing entries the image trusts.
		if len(entries) != 0 {
			fmt.Printf("Skipped: system CA directory is not empty: %s\n", path)
			return nil
		}
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("installation requires root; run as root with a writable /etc/ssl/certs")
	}
	source := filepath.Join(bundle, "etc", "ssl", "cacert.pem")
	in, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("cannot read bundled CA %s: %w", source, err)
	}
	defer in.Close()

	const target = "/etc/ssl/certs/ca-certificates.crt"
	// A root entrypoint's restrictive umask must not hide the store from
	// unprivileged TLS clients. This helper exits immediately after installing.
	syscall.Umask(022)
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return fmt.Errorf("cannot create system CA directory (requires a writable target): %w", err)
	}
	// O_EXCL also refuses a target that appeared after the store check.
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if err != nil {
		return fmt.Errorf("cannot install %s (requires a writable target; never overwrites): %w", target, err)
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		os.Remove(target)
		return fmt.Errorf("cannot write %s: %w", target, err)
	}
	fmt.Printf("Installed %s from %s\n", target, source)
	return nil
}
