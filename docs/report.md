# static-git report

Status of the bundle: what was tested, how fast it is, what does not work,
and what to do next.

Bundle: git 2.54.0, curl 8.22.0, OpenSSH 10.3p1, OpenSSL 3.5, mimalloc 2.2.7,
built on Alpine 3.24 (musl), for linux/amd64 and linux/arm64.

## Summary

- **It works everywhere we tried.** The smoke and matrix tests pass on amd64
  and arm64 (arm64 under QEMU) in 12 distribution images plus distroless and
  scratch, over HTTPS (public and private CA, through a proxy) and SSH,
  with the Buildkite agent's checkout commands.
- **It only fills gaps.** The image's CA store, ssh, `/etc/gitconfig` and
  every user setting we tested (`SSL_CERT_FILE`, `SSL_CERT_DIR`,
  `GIT_SSL_CAINFO`, `http.sslCAInfo`, `GIT_SSH_COMMAND`, proxies,
  `safe.directory`) win over the bundle's fallbacks.
- **Size:** 28 MB tarball, 62 MB unpacked (amd64); 28 MB and 58 MB (arm64).
- **Speed:** git is linked with mimalloc instead of musl's `malloc`. With
  it, the bundle is 10–30% faster than Alpine's own git (5x on `grep`), and
  within 10% of Debian's glibc git on clones, checkout, `blame` and `grep`.
  With musl's `malloc` it was 1.2–1.5x slower than Debian's git on that
  work, and 3x on `grep` (see [Performance](#performance)).
- **Launcher cost:** about 0.5 ms per git command (Go start-up plus one
  extra exec). A typical agent checkout runs about 20 git commands.

## What is tested

CI runs all of this on every build for both architectures
(`.buildkite/pipeline.yml`).

| Area | Checks | Script |
|---|---|---|
| Basics | `--version`, templates, `/etc/gitconfig` is the system config, child `PATH` order, every git binary uses mimalloc | smoke |
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
| clone --bare from GitHub | 14195 ± 569 | 18200 ± 1050 | 0.78 |
| clone --bare --no-local | 14433 ± 900 | 19836 ± 566 | 0.73 |
| checkout v2.30.0 -> v2.54.0 | 198 ± 4 | 218 ± 4 | 0.90 |
| status | 4.89 ± 0.25 | 4.50 ± 0.29 | 1.09 |
| log --oneline (all history) | 416 ± 11 | 456 ± 3 | 0.91 |
| diff --stat v2.30.0 v2.54.0 | 827 ± 3 | 1070 ± 11 | 0.77 |
| blame Makefile | 625 ± 3 | 909 ± 6 | 0.69 |
| grep 'static int' | 9.01 ± 1.1 | 50 ± 3 | 0.18 |
| --version | 0.83 ± 0.11 | 0.25 ± 0.06 | 3.28 |
| --version (static without launcher) | 0.25 ± 0.04 | 0.25 ± 0.05 | 0.99 |

Bundle vs Debian 13's git (2.47.3, glibc):

| | static (ms) | debian (ms) | static / debian |
|---|---:|---:|---:|
| clone --bare from GitHub | 14021 ± 366 | 12929 ± 223 | 1.08 |
| clone --bare --no-local | 14250 ± 559 | 13282 ± 310 | 1.07 |
| checkout v2.30.0 -> v2.54.0 | 213 ± 12 | 200 ± 10 | 1.07 |
| status | 5.57 ± 0.5 | 4.46 ± 0.44 | 1.25 |
| log --oneline (all history) | 449 ± 14 | 460 ± 11 | 0.98 |
| diff --stat v2.30.0 v2.54.0 | 868 ± 13 | 740 ± 14 | 1.17 |
| blame Makefile | 673 ± 9 | 712 ± 16 | 0.94 |
| grep 'static int' | 14 ± 0.6 | 16 ± 1.4 | 0.90 |
| --version | 0.80 ± 0.2 | 0.34 ± 0.06 | 2.34 |
| --version (static without launcher) | 0.22 ± 0.04 | 0.31 ± 0.03 | 0.71 |

What this shows:

- On real work the bundle beats Alpine's git everywhere except `status`
  (a few ms, mostly start-up), and is within 10% of Debian's git except
  `status` and `diff`. The remaining gap there is musl's slower
  string and memory functions, which mimalloc does not replace.
- Start-up: the real git starts about 0.05 ms slower than without mimalloc,
  and still faster than Debian's git. The launcher adds about 0.5 ms.

### mimalloc

musl's `malloc` takes a global lock and returns freed memory to the kernel
eagerly. Multi-threaded git commands (`index-pack` during clone, `grep`)
spent most of their extra time in the kernel because of it: a local clone
used 7.7 s of system time vs 1.5 s with mimalloc and 1.7 s for Debian's git.

git is linked with Alpine's static `libmimalloc-insecure.a`, which replaces
`malloc`, `free` and the rest in every git binary, including
`git-remote-https`. ("insecure" is upstream's default build; Alpine's
default "secure" build adds guard pages and is slower.) The smoke test
checks that every binary in `libexec/git-core` starts mimalloc. ssh and the
launcher are unchanged.

Same machine, both bundles benchmarked one after the other. Ratio to
Debian's git, from the same run (lower is better):

| | musl malloc | mimalloc |
|---|---:|---:|
| clone --bare from GitHub | 1.29 | 1.08 |
| clone --bare --no-local | 1.43 | 1.07 |
| checkout v2.30.0 -> v2.54.0 | 1.22 | 1.07 |
| status | 1.40 | 1.25 |
| log --oneline (all history) | 1.07 | 0.98 |
| diff --stat v2.30.0 v2.54.0 | 1.25 | 1.17 |
| blame Makefile | 1.33 | 0.94 |
| grep 'static int' | 2.91 | 0.90 |
| --version (static without launcher) | 0.52 | 0.71 |

Costs, measured with GNU time (peak RSS of the largest process):

| | musl malloc | mimalloc | debian |
|---|---:|---:|---:|
| clone --bare from GitHub, peak RSS (MB) | 97 | 133 | 98 |
| clone --bare --no-local, peak RSS (MB) | 578 | 616 | 531 |
| grep 'static int', peak RSS (MB) | 7 | 34 | 9 |
| blame Makefile, peak RSS (MB) | 315 | 328 | 293 |

- More memory: up to about 40 MB more per process, from mimalloc's
  per-thread heaps.
- About 180 KB more per binary; the tarball grows by 0.6 MB.
- Each git process reserves (but does not use) 1 GiB of address space.
  This matters only under a tight `ulimit -v`.
- `MIMALLOC_*` environment variables change mimalloc's settings in git.
- One more library to keep up to date. It comes from the same Alpine branch
  as the others, and its version is in `VERSIONS`.

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

1. **Decide the fixed install path.** Still open from the plan. Nothing in
   the bundle depends on it.
2. **Add a native arm64 CI queue** if one becomes available. arm64 is built
   and tested under QEMU on amd64 agents, which works but is slow, and arm64
   can't be benchmarked that way, so mimalloc's gain there is expected but
   not measured.
3. **Size, if it matters:** `git-remote-http`, `git-http-fetch` and
   `git-http-push` are separate ~10 MB copies of libcurl and OpenSSL, and
   the server-side tools (`git-daemon`, `git-http-backend`, `git-shell`,
   `scalar`) add ~14 MB. Dropping `git-http-push` and the server-side tools
   saves ~23 MB unpacked. `git-http-push` is only for pushing over
   dumb HTTP (WebDAV).
