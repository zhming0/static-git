# AGENTS.md

Notes for coding agents working on this repository. Read [README.md](README.md)
for what the bundle is, [DEVELOPMENT.md](DEVELOPMENT.md) for how it is built
and tested, and [docs/report.md](docs/report.md) for test results and known
limits.

## What this is

A self-contained git bundle (static git, static OpenSSH client, CA bundle,
and a Go launcher at `bin/git`) that is unpacked into any Linux image, amd64
or arm64. The output is one tarball per architecture, not a single binary.

## Rules the bundle must keep

These are the point of the project. Do not break them, and add a test when
you touch one.

- **Fill gaps, never override.** The image's CA store, ssh, `/etc/gitconfig`
  and every user setting must win over the bundle's fallbacks.
- The launcher only appends `<bundle>/fallback/bin` to the end of `PATH`, and
  sets `SSL_CERT_FILE` only when neither `SSL_CERT_FILE` nor `SSL_CERT_DIR` is
  set. It must never set `GIT_SSH_COMMAND`, `GIT_SSH` or `GIT_SSL_CAINFO`.
- ssh must never go in `libexec/git-core`: git puts that directory first on
  a child's `PATH`, so an ssh there would override the image's.
- Never build git with `INSTALL_SYMLINKS`. It turns `libexec/git-core/git`
  into a link to `bin/git` (the launcher), and git then runs itself forever.
  `scripts/package.sh` rejects any symlink in the bundle.
- Every ELF file must be static. `scripts/package.sh` fails the build if not.
- git is built with `RUNTIME_PREFIX` (the bundle works from any path) and an
  absolute `sysconfdir=/etc` (the image's `/etc/gitconfig` still applies).
- curl has no compiled-in CA path, so the CA comes from `SSL_CERT_FILE`.

## Layout

| Path | What |
|---|---|
| `versions.env` | Every pinned version. A version bump is a change here only. |
| `keys/` | Release signing keys of git, curl and OpenSSH. `scripts/fetch-sources.sh` checks each source tarball's signature against them. |
| `Dockerfile`, `docker-bake.hcl` | The build. One bake target per arch. |
| `scripts/build-*.sh`, `scripts/fetch-sources.sh`, `scripts/package.sh` | Run inside the Alpine build stages. POSIX sh. |
| `launcher/` | The Go `bin/git`, with unit tests. |
| `scripts/smoke-test.sh` | Quick checks of a tarball in real images. |
| `scripts/matrix-test.sh` | Full test matrix against a local git server. |
| `scripts/bench.sh` | Speed against distro gits. |
| `scripts/test-lib.sh` | Helpers shared by the three scripts above. |
| `test/` | Files the test scripts copy into containers: the git server image, the agent checkout script, feature checks, the benchmark runner. |
| `.buildkite/` | CI pipeline and step scripts. |
| `docs/report.md` | Test coverage, benchmark results, limits, recommendations. |

## Versions

- Follow one Alpine stable branch. git, curl and OpenSSH are built from
  upstream source at the version that branch ships (its aports `APKBUILD`s).
  Other libraries come from the branch's packages, not pinned to exact `-rN`
  versions (Alpine deletes old ones).
- Source tarballs are checked by OpenPGP signature, not by checksum. Each must
  be signed by its own project's key in `keys/`, and the key's fingerprint is
  pinned in `scripts/fetch-sources.sh`. A key file or fingerprint change needs
  the new fingerprint confirmed from two independent upstream sources.
- `ALPINE_VERSION` in the `Dockerfile` must equal `versions.env` (the build
  checks). `GO_VERSION` in the `Dockerfile` must equal `mise.toml` (the
  launcher CI step checks).
- Tools for CI and local work are pinned in `mise.toml`. Run `mise install`.

## Build and test

Everything needs Docker with buildx. arm64 on an amd64 host needs QEMU:
`docker run --privileged --rm tonistiigi/binfmt:qemu-v10.2.3 --install arm64`.

```sh
docker buildx bake amd64                                      # -> dist/linux_amd64/
(cd launcher && CGO_ENABLED=0 go test ./...)                  # launcher
scripts/smoke-test.sh dist/linux_amd64/*.tar.gz linux/amd64   # ~1 min
scripts/matrix-test.sh dist/linux_amd64/*.tar.gz linux/amd64  # ~1 min amd64, ~5 min arm64
scripts/bench.sh dist/linux_amd64/*.tar.gz                    # ~7 min, native arch only
```

A full amd64 build takes a few minutes; arm64 under QEMU takes ~12. To test a
change that does not touch the build, download a tarball from the latest
passing `main` build's artifacts instead of rebuilding.

Which checks to run:

- Launcher change: unit tests, then the smoke and matrix tests.
- Build script or version change: build, then the smoke and matrix tests,
  ideally on both architectures.
- Test script change: run that script against an existing tarball.
- Any shell change: `shellcheck --external-sources` on the changed files.

The smoke and matrix tests clone from GitHub, so they need internet access.

## Writing tests

- Test images get the bundle by `COPY`, not a bind mount, because on hosted
  agents the Docker daemon is not on the same host. Use `image` and `run_in`
  from `scripts/test-lib.sh`.
- `image` uses `docker buildx build --load`, and the base must be a registry
  image: the hosted remote builder cannot see images built locally.
- Label every container, network and volume with `$id` so `cleanup` removes
  it.
- Scripts that run inside test images (`test/*.sh`) must be POSIX sh: they
  run under busybox ash and dash too.
- New matrix checks go in `scripts/matrix-test.sh`; update the table in
  `docs/report.md` and the list in `DEVELOPMENT.md` to match.

## CI (Buildkite)

- Pipeline: [zhming0/static-git](https://buildkite.com/zhming0/static-git),
  defined in `.buildkite/pipeline.yml`. Step logic lives in
  `.buildkite/steps/`, not inline in the YAML.
- Hosted queues are amd64 only. arm64 is built on the agent's own Docker
  daemon with a pinned QEMU, not the hosted remote builder: gcc segfaulted
  under the remote builder's QEMU.
- Steps run on the agent, not in a step image (a step image did not start on
  hosted agents). Download pinned, checksummed binaries or use mise.
- Matrix and benchmark steps download the bundle from their build step's
  artifacts. The benchmark is `soft_fail`.
- Check pipeline YAML changes with the Buildkite MCP `validate_pipeline` tool.
- The ShellCheck step lints `scripts/*.sh`, `.buildkite/steps/*`,
  `.buildkite/steps/lib/*.bash`, `test/*.sh` and `test/gitserver/*.sh`. Add
  any new script directory to `.buildkite/steps/shellcheck`.

## Style

- Shell: ShellCheck-clean. Scripts under `scripts/` and `test/` use tabs;
  `.buildkite/steps/` use two spaces. Use bash only for scripts that run on
  the host; scripts that run inside the build or test images are POSIX sh.
- Go: `gofmt`, `go vet`, cgo off.
- Comments say why, not what. Keep the existing header comment on each
  script up to date (usage and what it checks).
- Plain technical English in code, docs, commits and PRs. No jargon.

## Pull requests

- One commit per PR. Keep the PR description up to date with what changed,
  what was tested and any change from the plan.
- Do not commit `dist/`, `bench.md` or other build output.
- When behaviour or results change, update `README.md`, `DEVELOPMENT.md` and
  `docs/report.md` in the same PR.
