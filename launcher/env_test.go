package main

import (
	"slices"
	"testing"
)

const bundle = "/opt/static-git"

func files(paths ...string) func(string) bool {
	return func(p string) bool { return slices.Contains(paths, p) }
}

func get(t *testing.T, env []string, key string) (string, bool) {
	t.Helper()
	_, v, ok := lookup(env, key)
	return v, ok
}

func TestPath(t *testing.T) {
	fb := bundle + "/fallback/bin"
	cases := []struct {
		name string
		env  []string
		want string
	}{
		{"appended last", []string{"PATH=/usr/bin:/bin"}, "/usr/bin:/bin:" + fb},
		{"unset uses musl default", nil, muslDefaultPath + ":" + fb},
		{"empty does not add cwd", []string{"PATH="}, fb},
		{"not added twice", []string{"PATH=/usr/bin:" + fb}, "/usr/bin:" + fb},
		{"appended even if also earlier", []string{"PATH=" + fb + ":/usr/bin"}, fb + ":/usr/bin:" + fb},
		{"first entry wins", []string{"PATH=/a", "PATH=/b"}, "/a:" + fb},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := get(t, fallbackEnv(c.env, bundle, files()), "PATH")
			if !ok || got != c.want {
				t.Fatalf("PATH = %q (set %v), want %q", got, ok, c.want)
			}
		})
	}
}

func TestCA(t *testing.T) {
	cases := []struct {
		name    string
		env     []string
		files   []string
		want    string
		wantSet bool
	}{
		{
			name:    "debian bundle",
			files:   []string{"/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem"},
			want:    "/etc/ssl/certs/ca-certificates.crt",
			wantSet: true,
		},
		{
			name:    "rhel bundle",
			files:   []string{"/etc/pki/tls/certs/ca-bundle.crt"},
			want:    "/etc/pki/tls/certs/ca-bundle.crt",
			wantSet: true,
		},
		{
			name:    "openssl default name",
			files:   []string{"/etc/ssl/cert.pem"},
			want:    "/etc/ssl/cert.pem",
			wantSet: true,
		},
		{
			name:    "suse bundle",
			files:   []string{"/etc/ssl/ca-bundle.pem"},
			want:    "/etc/ssl/ca-bundle.pem",
			wantSet: true,
		},
		{
			name:    "no system store uses bundled",
			want:    bundle + "/etc/ssl/cacert.pem",
			wantSet: true,
		},
		{
			name:    "user SSL_CERT_FILE kept",
			env:     []string{"SSL_CERT_FILE=/my/ca.pem"},
			files:   []string{"/etc/ssl/certs/ca-certificates.crt"},
			want:    "/my/ca.pem",
			wantSet: true,
		},
		{
			name:    "user empty SSL_CERT_FILE kept",
			env:     []string{"SSL_CERT_FILE="},
			want:    "",
			wantSet: true,
		},
		{
			name:    "user SSL_CERT_DIR means no SSL_CERT_FILE",
			env:     []string{"SSL_CERT_DIR=/my/certs"},
			files:   []string{"/etc/ssl/certs/ca-certificates.crt"},
			wantSet: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := get(t, fallbackEnv(c.env, bundle, files(c.files...)), "SSL_CERT_FILE")
			if ok != c.wantSet || got != c.want {
				t.Fatalf("SSL_CERT_FILE = %q (set %v), want %q (set %v)", got, ok, c.want, c.wantSet)
			}
		})
	}
}

func TestNeverSetsGitOverrides(t *testing.T) {
	env := fallbackEnv(nil, bundle, files())
	for _, key := range []string{"GIT_SSH_COMMAND", "GIT_SSH", "GIT_SSL_CAINFO", "GIT_EXEC_PATH"} {
		if _, ok := get(t, env, key); ok {
			t.Errorf("%s must never be set by the launcher", key)
		}
	}
}

func TestKeepsOtherVariables(t *testing.T) {
	in := []string{"HOME=/root", "GIT_SSH_COMMAND=ssh -v", "PATH=/bin"}
	out := fallbackEnv(in, bundle, files())
	for _, kv := range []string{"HOME=/root", "GIT_SSH_COMMAND=ssh -v"} {
		if !slices.Contains(out, kv) {
			t.Errorf("lost %q", kv)
		}
	}
	if in[2] != "PATH=/bin" {
		t.Errorf("input slice was modified: %q", in[2])
	}
}
