package main

import (
	"path/filepath"
	"strings"
)

// muslDefaultPath is what musl's execvp searches when PATH is unset. The real
// git is linked against musl, so this is the search path it would use anyway.
const muslDefaultPath = "/usr/local/bin:/bin:/usr/bin"

// systemCAFiles are the CA bundles distributions install, in probe order.
var systemCAFiles = []string{
	"/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Alpine, Arch
	"/etc/pki/tls/certs/ca-bundle.crt",   // RHEL, Rocky, Fedora, Amazon Linux
	"/etc/ssl/cert.pem",                  // OpenSSL's default name, LibreSSL
	"/etc/ssl/ca-bundle.pem",             // openSUSE
}

// fallbackEnv returns env with the bundle's fallbacks added at the lowest
// priority. It only fills gaps: anything the image or the user already set
// keeps working the same way.
//
//   - <bundle>/fallback/bin is appended to the end of PATH, so an ssh already
//     on PATH wins over the bundled one.
//   - If neither SSL_CERT_FILE nor SSL_CERT_DIR is set, SSL_CERT_FILE points at
//     the first system CA bundle found, else at the bundled one. git's
//     http.sslCAInfo and GIT_SSL_CAINFO still override it.
//
// It never sets GIT_SSH_COMMAND, GIT_SSH or GIT_SSL_CAINFO.
func fallbackEnv(env []string, bundle string, isFile func(string) bool) []string {
	out := make([]string, len(env))
	copy(out, env)

	fallbackBin := filepath.Join(bundle, "fallback", "bin")
	if i, path, ok := lookup(out, "PATH"); !ok {
		out = append(out, "PATH="+muslDefaultPath+":"+fallbackBin)
	} else if path == "" {
		// An empty PATH element means the current directory, so do not
		// produce ":<fallback>".
		out[i] = "PATH=" + fallbackBin
	} else if !hasLastElement(path, fallbackBin) {
		out[i] = "PATH=" + path + ":" + fallbackBin
	}

	_, _, hasFile := lookup(out, "SSL_CERT_FILE")
	_, _, hasDir := lookup(out, "SSL_CERT_DIR")
	if !hasFile && !hasDir {
		out = append(out, "SSL_CERT_FILE="+caFile(bundle, isFile))
	}

	return out
}

// caFile returns the first system CA bundle that exists, else the bundled one.
func caFile(bundle string, isFile func(string) bool) string {
	for _, f := range systemCAFiles {
		if isFile(f) {
			return f
		}
	}
	return filepath.Join(bundle, "etc", "ssl", "cacert.pem")
}

// lookup finds the first entry for key, which is the one getenv(3) returns.
func lookup(env []string, key string) (index int, value string, ok bool) {
	prefix := key + "="
	for i, kv := range env {
		if strings.HasPrefix(kv, prefix) {
			return i, kv[len(prefix):], true
		}
	}
	return -1, "", false
}

// hasLastElement reports whether dir is already the last PATH element, so a
// git that re-runs the launcher does not grow PATH every time.
func hasLastElement(path, dir string) bool {
	elems := strings.Split(path, ":")
	return elems[len(elems)-1] == dir
}
