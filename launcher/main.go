// Command git is the bundle's entry point, installed as <bundle>/bin/git. It
// adds ssh and CA certificate fallbacks at the lowest priority (see
// fallbackEnv), then replaces itself with <bundle>/libexec/git-core/git.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func main() {
	self, err := selfPath()
	if err != nil {
		fail("cannot find own path: %v", err)
	}
	// <bundle>/bin/git -> <bundle>
	bundle := filepath.Dir(filepath.Dir(self))
	realGit := filepath.Join(bundle, "libexec", "git-core", "git")

	env := fallbackEnv(os.Environ(), bundle, isFile)

	// argv[0] is the real git's absolute path. git also derives its runtime
	// prefix from argv[0] when /proc/self/exe is unavailable.
	argv := append([]string{realGit}, os.Args[1:]...)
	err = syscall.Exec(realGit, argv, env)
	fail("exec %s: %v", realGit, err)
}

// selfPath returns the launcher's real path with symlinks resolved, so a
// symlink such as /usr/local/bin/git -> <bundle>/bin/git still finds the
// bundle.
func selfPath() (string, error) {
	p, err := os.Executable()
	if err != nil {
		// No /proc: fall back to argv[0].
		if p, err = exec.LookPath(os.Args[0]); err != nil {
			return "", err
		}
		if p, err = filepath.Abs(p); err != nil {
			return "", err
		}
	}
	return filepath.EvalSymlinks(p)
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "git (static-git launcher): "+format+"\n", args...)
	os.Exit(128)
}
