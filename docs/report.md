# static-git report

Status of the bundle after milestones 1–7: what was tested, how fast it is,
what does not work, and what to do next.

Bundle: git 2.54.0, curl 8.22.0, OpenSSH 10.3p1, OpenSSL 3.5, built on
Alpine 3.24 (musl), for linux/amd64 and linux/arm64.

## Summary

- **It works everywhere we tried.** The smoke and matrix tests pass on amd64
  and arm64 (arm64 under QEMU) in 12 distribution images plus distroless and
  scratch, over HTTPS (public and private CA, through a proxy) and SSH,
  with the Buildkite agent's checkout commands.
- **It only fills gaps.** The image's CA store, ssh, `/etc/gitconfig` and
  every user setting we tested (`SSL_CERT_FILE`, `SSL_CERT_DIR`,
  `GIT_SSL_CAINFO`, `http.sslCAInfo`, `GIT_SSH_COMMAND`, proxies,
  `safe.directory`) win over the bundle's fallbacks.
- **Size:** 27 MB tarball, 60 MB unpacked (amd64); 28 MB and 57 MB (arm64).
- **Speed:** the same as Alpine's own git, but 1.2–1.5x slower than Debian's
  glibc git on CPU-heavy work, and about 1.3x slower on a large clone from
  GitHub. The cause is musl's `malloc`. Linking mimalloc into git removes
  most of the gap (see [Performance](#performance)). This is the main
  recommendation.
- **Launcher cost:** about 0.4 ms per git command (Go start-up plus one
  extra exec). A typical agent checkout runs about 20 git commands.

## What is tested

CI runs all of this on every build for both architectures
(`.buildkite/pipeline.yml`).

| Area | Checks | Script |
|---|---|---|
| Basics | `--version`, templates, `/etc/gitconfig` is the system config, child `PATH` order | smoke |
| HTTPS, no config | alpine, debian-slim, busybox, distroless, scratch | smoke |
| CA precedence | no CA without the launcher; `GIT_SSL_CAINFO`, `http.sslCAInfo` win | smoke |
| SSH | RSA, ECDSA, ed25519 keys through the bundled ssh; the image's ssh wins | smoke |
| Distributions | Alpine 3.24, Debian 12/13 (with and without `ca-certificates`), Ubuntu 22.04/24.04, Rocky 9, UBI 9 minimal, Fedora 42, Amazon Linux 2023, openSUSE Leap 15.6, busybox: the right CA file is picked, GitHub clone, agent checkout over authenticated HTTPS | matrix |
| Agent checkout | clone, clean, fetch, `checkout -f`, submodules (relative URL), a `refs/pull/N/head` commit on no branch, reuse of a dirty checkout, mirrors with `--reference`, sparse blobless clone, shallow clone, push of a tag and branch | `test/agent-checkout.sh` |
| Private CA | unknown CA fails; the distro's own way of adding a CA (`update-ca-certificates`, `update-ca-trust`) works; `SSL_CERT_FILE`, `SSL_CERT_DIR`, `http.sslCAInfo`, `http.<url>.sslCAInfo`, `GIT_SSL_NO_VERIFY` | matrix |
| Proxy | `https_proxy`, `HTTPS_PROXY`, `http.proxy`, `no_proxy`, to a host only the proxy can resolve | matrix |
| safe.directory | repo owned by another user is refused; allowed from `/etc/gitconfig`, global config, `-c`, `GIT_CONFIG_COUNT`; repo config is ignored | matrix |
| Agent checkout over SSH | bundled ssh with default key and `known_hosts`, in debian, rocky, busybox; the agent's `GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"` with no `known_hosts` | matrix |
| Runtime | random UID with no passwd entry (HTTPS), read-only root, symlink to `bin/git` on `PATH`, bundle path with a space, `env -i` | matrix |
| Features | hooks, PCRE2 (`grep -P`), iconv, `archive`, `worktree`, `bundle`, `clone --no-local`, `gc`, `fsck`, `format-patch`/`am`, `rebase -i`, `bisect run`, `stash`, `credential-cache`, `credential-store` | `test/features.sh` |

The matrix test uses a local git server (`test/gitserver`): HTTPS from
`git-http-backend` with a private CA and basic auth, sshd, and tinyproxy.
Only GitHub clones need the internet. It takes about 40 s on amd64 and
5 minutes on arm64 under QEMU.

## Performance

`scripts/bench.sh` times the bundle's git against the image's own git with
hyperfine, on a bare clone of git/git in a tmpfs. These numbers are from a
4-CPU amd64 machine; CI adds the same tables to every build as an
annotation.

Bundle vs Alpine 3.24's git (same git version, musl, dynamically linked):

| | static (ms) | alpine (ms) | static / alpine |
|---|---:|---:|---:|
| clone --bare from GitHub | 12050 ± 339 | 13579 ± 611 | 0.89 |
| clone --bare --no-local | 14264 ± 253 | 16530 ± 106 | 0.86 |
| checkout v2.30.0 -> v2.54.0 | 217 ± 4 | 219 ± 3 | 0.99 |
| status | 4.43 ± 0.49 | 3.83 ± 0.27 | 1.16 |
| log --oneline (all history) | 465 ± 15 | 498 ± 4 | 0.93 |
| diff --stat v2.30.0 v2.54.0 | 871 ± 15 | 1043 ± 51 | 0.83 |
| blame Makefile | 954 ± 5 | 993 ± 20 | 0.96 |
| grep 'static int' | 45 ± 6 | 43 ± 4 | 1.04 |
| --version | 0.68 ± 0.18 | 0.25 ± 0.08 | 2.67 |
| --version (static without launcher) | 0.15 ± 0.03 | 0.23 ± 0.06 | 0.64 |

Bundle vs Debian 13's git (2.47.3, glibc):

| | static (ms) | debian (ms) | static / debian |
|---|---:|---:|---:|
| clone --bare from GitHub | 14845 ± 619 | 11199 ± 499 | 1.33 |
| clone --bare --no-local | 15791 ± 1055 | 10406 ± 136 | 1.52 |
| checkout v2.30.0 -> v2.54.0 | 211 ± 2 | 172 ± 1 | 1.22 |
| status | 3.73 ± 0.2 | 2.86 ± 0.2 | 1.31 |
| log --oneline (all history) | 432 ± 3 | 429 ± 7 | 1.01 |
| diff --stat v2.30.0 v2.54.0 | 862 ± 16 | 727 ± 20 | 1.18 |
| blame Makefile | 873 ± 18 | 697 ± 13 | 1.25 |
| grep 'static int' | 36 ± 5 | 13 ± 2 | 2.74 |
| --version | 0.59 ± 0.12 | 0.32 ± 0.07 | 1.87 |
| --version (static without launcher) | 0.16 ± 0.03 | 0.31 ± 0.07 | 0.51 |

What this shows:

- Static linking itself costs nothing: without the launcher, the static git
  starts faster than either distro git, and it matches Alpine's git on real
  work.
- The gap to Debian is musl. The slow cases are the multi-threaded ones
  (`index-pack` during clone, `grep`), and they spend far more time in the
  kernel: `grep` with 4 threads used 77 ms of system time vs 16 ms for
  Debian's git, and the local clone 6.2 s vs 1.3 s. That is musl's `malloc`
  returning memory to the kernel and taking a global lock.
- In an agent checkout, only the first clone of a large repo is affected
  noticeably: git/git (about 300 MB) from GitHub took about 3.5 s longer.

### Experiment: mimalloc

Not shipped. To test the `malloc` theory, git was rebuilt with mimalloc
2.2.7 (the version Alpine 3.24 packages) linked in as a static object, which
replaces musl's `malloc`. Same machine, Debian 13 image, mean of runs:

| | static | static + mimalloc | debian |
|---|---:|---:|---:|
| clone --bare --no-local (s) | 13.73 | 11.78 | 11.00 |
| clone --bare from GitHub, 3 runs (s) | 13.88 | 11.72 | 10.80 |
| checkout v2.30.0 -> v2.54.0 (ms) | 207 | 200 | 174 |
| status (ms) | 4.7 | 4.0 | 3.0 |
| blame Makefile (ms) | 941 | 652 | 672 |
| grep 'static int' (ms) | 32.3 | 11.4 | 10.6 |
| peak RSS, clone from GitHub (MB) | 97 | 137 | 97 |

mimalloc brings clone, `grep` and `blame` to within 0–10% of glibc git. The
remaining 10–20% on checkout and diff is musl's slower string and memory
functions. The costs: about 40% more peak memory during a clone, about
140 KB more per binary, and one more library to keep up to date. Each git
process also reserves (but does not use) 1 GiB of address space, which
matters only under a tight `ulimit -v`.

## Known limits

Unchanged from the earlier PR, plus what the matrix test found:

- **SSH needs a passwd entry for the UID.** HTTPS works with a random UID;
  OpenSSH refuses to start without a user name.
- **No `ssh-keygen`, `ssh-keyscan`, `ssh-agent`, `ssh-add`.** Plain
  checkouts do not need them: the current agent uses
  `StrictHostKeyChecking=accept-new` instead of `ssh-keyscan`, and the
  bundled ssh handles that. SSH commit signing (`gpg.format=ssh`) needs
  `ssh-keygen` from the image.
- **No git-lfs.** With `BUILDKITE_GIT_LFS_ENABLED=true` the agent's checkout
  fails fast on `git lfs version`.
- **No man pages or translations.** `git help <cmd>` and `git <cmd> --help`
  fail; `git <cmd> -h` prints the usage.
- **musl has no NSS.** Host names come from `/etc/hosts` and DNS only.
- **The launcher's `SSL_CERT_FILE` is inherited** by hooks and tools that git
  runs. It points at the image's own store whenever there is one.

## Recommendations

1. **Link mimalloc into git** (follow-up PR). It closes most of the speed
   gap; the matrix test already covers the behaviour it could break. Use the
   version Alpine packages, as for the other libraries.
2. **Decide the fixed install path.** Still open from the plan. Nothing in
   the bundle depends on it.
3. **Add a native arm64 CI queue** if one becomes available. arm64 is built
   and tested under QEMU on amd64 agents, which works but is slow, and arm64
   can't be benchmarked that way.
4. **Size, if it matters:** `git-remote-http`, `git-http-fetch` and
   `git-http-push` are separate ~10 MB copies of libcurl and OpenSSL, and
   the server-side tools (`git-daemon`, `git-http-backend`, `git-shell`,
   `scalar`) add ~14 MB. Dropping `git-http-push` and the server-side tools
   saves ~23 MB unpacked. `git-http-push` is only for pushing over
   dumb HTTP (WebDAV).
