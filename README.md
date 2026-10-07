# static-git

A self-contained git bundle that can be injected into any Linux image
(amd64, arm64) and works with zero setup. It never changes behaviour the image
or user already has: it only **fills gaps, never overrides**.

## What is in the bundle

```
bin/git                     launcher (static Go)
libexec/git-core/           real git and its helpers, static musl
share/git-core/templates/
fallback/bin/ssh            static OpenSSH client
etc/ssl/cacert.pem          CA bundle
VERSIONS                    every component version
```

Run `<bundle>/bin/git`. The launcher:

1. Appends `<bundle>/fallback/bin` to the **end** of `PATH`, so the image's own
   `ssh` wins when it has one. `GIT_SSH_COMMAND`, `core.sshCommand` and
   `GIT_SSH` win over `PATH` anyway.
2. If neither `SSL_CERT_FILE` nor `SSL_CERT_DIR` is set, sets `SSL_CERT_FILE` to
   the first system CA bundle it finds (Debian, RHEL, OpenSSL and SUSE paths),
   else to the bundled one. `http.sslCAInfo` and `GIT_SSL_CAINFO` still win.
3. Execs `<bundle>/libexec/git-core/git` with the same arguments.

It never sets `GIT_SSH_COMMAND` or `GIT_SSL_CAINFO`. ssh is never put in
`libexec/git-core`, because git prepends that directory to `PATH`.

git is built with `RUNTIME_PREFIX`, so the bundle can be unpacked anywhere, and
with an absolute `sysconfdir=/etc`, so the image's `/etc/gitconfig` (for
example `safe.directory`) still applies.

Not included: Perl/Python/Tcl commands (`send-email`, `svn`, `p4`, `gitk`),
`imap-send`, translations, `ssh-agent`/`ssh-add`/`ssh-keyscan`, git-lfs, and
FIDO (`-sk`) SSH keys.

## Build

Needs Docker with buildx.

```sh
docker buildx bake amd64     # -> dist/linux_amd64/
docker buildx bake arm64     # -> dist/linux_arm64/ (QEMU on an amd64 host)
docker buildx bake all       # both
```

On an amd64 host, install the arm64 QEMU handlers once:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Each build writes `static-git-<git version>-linux-<arch>.tar.gz`, its
`.sha256`, and a `.sizes.txt` report. The tarball has no top-level directory:

```sh
mkdir -p /opt/static-git
tar -C /opt/static-git -xzf static-git-*-linux-amd64.tar.gz
/opt/static-git/bin/git --version
```

## Test

```sh
mise install                                                 # Go, pinned in mise.toml
(cd launcher && go test ./...)                               # launcher unit tests
scripts/smoke-test.sh dist/linux_amd64/*.tar.gz linux/amd64  # bundle in real images
```

The smoke test checks templates, `/etc/gitconfig`, the child `PATH` order,
HTTPS clones with no config in `alpine`, `debian:bookworm-slim`, `busybox`,
`distroless/static` and `scratch`, CA precedence, SSH clones with RSA, ECDSA
and ed25519 keys through the bundled ssh, and that an ssh already in the image
is preferred.

CI runs on Buildkite (`.buildkite/pipeline.yml`) for both architectures and
keeps the tarballs as build artifacts.

## Versions

[`versions.env`](versions.env) is the single place to bump versions. The bundle
follows one Alpine stable branch: git, curl and OpenSSH are built from upstream
source at the version that branch ships; OpenSSL, zlib, expat, pcre2, nghttp2
and the CA bundle are that branch's packages. The exact package versions used
are recorded in each bundle's `VERSIONS` file.

## Known limits

- OpenSSH needs a `/etc/passwd` entry for the current UID. Running as a random
  UID with no entry (`docker run --user 12345`) makes ssh fail with
  "No user exists for uid". This is not caused by the static build.
- musl has no NSS plugins, so host lookups use `/etc/hosts` and DNS only.
- `SSL_CERT_FILE` set by the launcher is inherited by hooks. It points at the
  system store whenever there is one.
