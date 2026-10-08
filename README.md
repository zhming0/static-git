# static-git

A static git you can drop into any Linux image (amd64, arm64) and run with
zero setup: HTTPS and SSH work out of the box, even in `scratch` or
distroless images.

## Why

CI agents such as the Buildkite agent need git inside whatever image a job
runs in. Many images have no git, an old one, or no CA certificates or ssh,
and installing git differs on every distribution. This bundle is one tarball
that works the same everywhere, without changing anything the image already
sets up.

## What you get

- git, an OpenSSH client, git-lfs and a CA bundle, all static. No libc or
  packages needed.
- **Fills gaps, never overrides.** The image's CA store, ssh, git-lfs,
  `/etc/gitconfig` and your own settings (`SSL_CERT_FILE`, `GIT_SSH_COMMAND`,
  `http.sslCAInfo`, proxies, `safe.directory`, ...) always win. The bundled
  ssh, git-lfs and CA bundle are used only when the image has none.
- Works from any directory, including through a symlink.
- Tested in 12 distributions plus busybox, distroless and `scratch`, over
  HTTPS, SSH, private CAs and proxies. About as fast as Debian's git. See
  [docs/report.md](docs/report.md).

## Use

Download a tarball from
[Releases](https://github.com/zhming0/static-git/releases). It has no
top-level directory:

```sh
mkdir -p /opt/static-git
tar -C /opt/static-git -xzf static-git-*-linux-amd64.tar.gz
/opt/static-git/bin/git --version
```

The bundle is meant to be laid over an existing image or machine as one
directory. To add `git` and leave everything else as it was:

1. **Keep it in its own directory**, such as `/opt/static-git`. Do not unpack
   it into `/` or `/usr`. Nothing outside that directory is written or needed,
   so removing it is `rm -rf /opt/static-git`. It can be read-only.
2. **Expose only `bin/git`.** Run it by full path, add `<bundle>/bin` to the
   end of `PATH` (`bin/` holds nothing else), or symlink it into a directory
   already on `PATH`. Adding it to the end of `PATH` lets an image's own git
   win; put it first if you always want the bundle's git.
3. **Do not put `libexec/git-core` or `fallback/bin` on `PATH`**, and do not
   set `SSL_CERT_FILE` for it. `bin/git` is a small launcher that adds the
   bundled ssh, git-lfs and CA bundle only for git and the programs git
   starts (ssh, git-lfs, hooks), and only when the image has none. Other
   programs see no change.

In a Dockerfile:

```dockerfile
FROM alpine AS static-git
ADD https://github.com/zhming0/static-git/releases/download/<tag>/static-git-<version>-linux-amd64.tar.gz /tmp/static-git.tar.gz
RUN mkdir /opt/static-git && tar -C /opt/static-git -xzf /tmp/static-git.tar.gz

FROM your-image
COPY --from=static-git /opt/static-git /opt/static-git
ENV PATH="$PATH:/opt/static-git/bin"
```

Or mount it into a container that is already built:

```sh
docker run -v /opt/static-git:/opt/static-git:ro your-image /opt/static-git/bin/git --version
```

In Kubernetes, an init container can copy the bundle into a shared
`emptyDir` volume that the main container mounts read-only.

### Git LFS

`git lfs` works with no setup, but the bundle does not turn on the LFS
filters, so a plain clone leaves LFS files as pointers. Run `git lfs install`
once (or `git lfs install --local` in a repository), or `git lfs pull` after
the clone. The Buildkite agent does this itself when
`BUILDKITE_GIT_LFS_ENABLED=true`.

## Known limits

- SSH needs an `/etc/passwd` entry for the current UID. HTTPS does not.
- Host lookups use `/etc/hosts` and DNS only (no NSS plugins).
- Hooks and git-lfs inherit the `SSL_CERT_FILE` the launcher sets.
- Not included: Perl/Python/Tcl commands (`send-email`, `svn`, `p4`, `gitk`),
  `imap-send`, translations, `ssh-agent`/`ssh-add`/`ssh-keyscan`, and FIDO
  (`-sk`) SSH keys.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md).
