# Developing static-git

How the bundle is built, tested and released. For what it is and how to use
it, see [README.md](README.md). Test results, benchmarks and open questions
are in [docs/report.md](docs/report.md).

## How it works

```
bin/git                     launcher (static Go)
libexec/git-core/           real git and its helpers, static musl
share/git-core/templates/
fallback/bin/ssh            static OpenSSH client
etc/ssl/cacert.pem          CA bundle
VERSIONS                    every component version
```

`bin/git` is a small launcher. It:

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
example `safe.directory`) still applies. It is linked with mimalloc instead of
musl's `malloc`, which is slow in multi-threaded commands such as clone and
`grep`; see [docs/report.md](docs/report.md#mimalloc). `MIMALLOC_*`
environment variables affect git.

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
`.sha256`, and a `.sizes.txt` report.

## Test

```sh
mise install                                                  # Go, pinned in mise.toml
(cd launcher && go test ./...)                                # launcher unit tests
scripts/smoke-test.sh dist/linux_amd64/*.tar.gz linux/amd64   # quick check in real images
scripts/matrix-test.sh dist/linux_amd64/*.tar.gz linux/amd64  # full test matrix
scripts/bench.sh dist/linux_amd64/*.tar.gz                    # speed vs distro git (native only)
```

The smoke test checks templates, `/etc/gitconfig`, the child `PATH` order,
that every git binary uses mimalloc, HTTPS clones with no config in `alpine`,
`debian:bookworm-slim`, `busybox`, `distroless/static` and `scratch`, CA
precedence, SSH clones with RSA, ECDSA and ed25519 keys through the bundled
ssh, and that an ssh already in the image is preferred.

The matrix test starts a local git server (`test/gitserver`: HTTPS with a
private CA and basic auth, SSH, and an HTTP proxy) and checks:

- 12 images (Alpine, Debian, Ubuntu, Rocky, UBI, Fedora, Amazon Linux,
  openSUSE, busybox): which CA store is picked, an HTTPS clone from GitHub,
  and the Buildkite agent's checkout commands (`test/agent-checkout.sh`:
  clone, clean, fetch, checkout, submodules, a PR ref, mirrors, sparse
  blobless clone, shallow clone, push) over authenticated HTTPS.
- Private CA: the image's store after the distro's update tool,
  `SSL_CERT_FILE`, `SSL_CERT_DIR`, `http.sslCAInfo`, per-URL config,
  `GIT_SSL_NO_VERIFY`.
- Proxy: `https_proxy`, `HTTPS_PROXY`, `http.proxy`, `no_proxy`.
- `safe.directory` from each trusted scope, and that repo config is ignored.
- The agent's checkout commands over SSH with the bundled ssh.
- A random UID, a read-only root, a symlink to `bin/git` on `PATH`, a bundle
  path with a space, and an empty environment.
- Build-dependent features (`test/features.sh`): PCRE2, iconv, hooks,
  `rebase -i`, `gc`, `credential-cache`, and more.

CI runs on Buildkite (`.buildkite/pipeline.yml`): build and smoke test, then
the matrix test, for both architectures, and the benchmark on amd64. The
tarballs and `bench.md` are kept as build artifacts.

## Release

On `main`, after every test passes, a manual block step releases the build.
`.buildkite/steps/create-github-release` picks a calendar version
(`2026.10.7-1123456`), creates that tag at the built commit, and uploads both
tarballs and their `.sha256` files to a
[GitHub release](https://github.com/zhming0/static-git/releases). It uses the
`GITHUB_TOKEN` cluster secret. The release commits nothing to the repository.

## Versions

[`versions.env`](versions.env) is the single place to bump versions. The bundle
follows one Alpine stable branch: git, curl and OpenSSH are built from upstream
source at the version that branch ships; OpenSSL, zlib, expat, pcre2, nghttp2,
mimalloc and the CA bundle are that branch's packages. The exact package
versions used are recorded in each bundle's `VERSIONS` file.

The git, curl and OpenSSH source tarballs are checked by their OpenPGP
signatures, not by a checksum per version. Each project signs its releases,
and [`scripts/fetch-sources.sh`](scripts/fetch-sources.sh) checks each tarball
against its own project's key in [`keys/`](keys/):

| Project | Signer | Key fingerprint |
|---|---|---|
| git | Junio C Hamano | `96E0 7AF2 5771 9559 80DA  D100 20D0 4E5A 7136 60A7` |
| curl | Daniel Stenberg | `27ED EAF2 2F3A BCEB 50DB  9A12 5CC9 08FD B71E 12C2` |
| OpenSSH | Damien Miller | `7168 B983 815A 5EEF 59A4  ADFD 2A3F 414E 7360 60BA` |

So a version bump is only a change to `versions.env`; the build fails if the
new tarball is not signed by the expected key. A project rarely changes its
signing key. When it does, export only the new key into `keys/` with
`gpg --armor --export-options export-minimal --export <fingerprint>`, update
the fingerprint in `fetch-sources.sh`, and confirm the fingerprint from two
independent upstream sources (for example the project's download page and its
maintainer's GitHub or kernel.org key).
