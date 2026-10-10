#!/usr/bin/env bash
# Full test matrix for one bundle tarball. Slower than smoke-test.sh, and
# needs a local git server, which runs in a container (test/gitserver).
#
# Usage: matrix-test.sh <static-git-*.tar.gz> <platform, e.g. linux/arm64>
#
# Needs only docker (see test-lib.sh).
#
# Checks:
#   - distributions: CA store detection, HTTPS clone from GitHub, and the
#     Buildkite agent's checkout commands, with Git LFS, over authenticated
#     HTTPS
#   - private CA: the image's CA store, SSL_CERT_FILE, SSL_CERT_DIR,
#     http.sslCAInfo, per-URL config, GIT_SSL_NO_VERIFY, for both git and
#     git-lfs
#   - HTTP proxy: https_proxy, HTTPS_PROXY, http.proxy, no_proxy, for both
#     git and git-lfs
#   - safe.directory: every scope git trusts, and that it is still enforced
#   - the agent's checkout commands, with Git LFS, over SSH with the bundled
#     ssh
#   - runtime: random UID, read-only root, symlink on PATH, path with spaces,
#     empty environment
#   - git features that depend on the build (test/features.sh)
set -euo pipefail

tarball=$1
platform=$2
here=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=scripts/test-lib.sh
. "$here/scripts/test-lib.sh"

GITHUB_REPO=https://github.com/octocat/Hello-World.git
PRIVATE_REPO=https://gitserver/main.git

echo "--- :package: $(basename "$tarball") on $platform"
cat "$work/bundle/VERSIONS"

echo "--- :whale: Test git server"
# The server runs natively; only the clients are the platform under test.
docker buildx build -q --load -t "$id:gitserver" "$here/test/gitserver" >/dev/null
new_network
docker run -d --label "$id" --name "$id-server" --network "$id" \
	--network-alias gitserver "$id:gitserver" >/dev/null
wait_ready "$id-server"
mkdir "$work/export"
docker exec "$id-server" tar -C /export -cf - . | tar -C "$work/export" -xf -
cp "$here/test/agent-checkout.sh" "$here/test/features.sh" "$work/export/"
MAIN_SHA=$(cat "$work/export/main.sha")
PR_SHA=$(cat "$work/export/pr.sha")
CA_HASH=$(cat "$work/export/ca.hash")
pass "git server is up"

# client <tag> <base>: a test image with the bundle at $B and the server's
# files (CA, SSH key, test scripts) at /test.
client() {
	image "$1" "$2" <<<"COPY export/ /test/"
}

# Options for run_in: the agent checkout's inputs (in $job), and a
# credential helper for the authenticated HTTPS URL.
agent_job() {
	job=(-e "MAIN_SHA=$MAIN_SHA" -e "PR_SHA=$PR_SHA" -e "JOB=$1")
}
creds=(
	-e GIT_CONFIG_COUNT=1
	-e GIT_CONFIG_KEY_0=credential.helper
	-e 'GIT_CONFIG_VALUE_0=!f() { echo username=agent; echo password=s3cret; }; f'
)

# Clone the private repo with whatever CA setup the command set up first,
# then download its LFS file, so git-lfs (Go, not libcurl) must accept the
# same setup.
lfs_pull="git lfs install --local >/dev/null && git lfs pull && grep -qx 'stored in git lfs' lfs.dat"
clone_private="cd /tmp && rm -rf r && git clone -q $PRIVATE_REPO r && cd r && test -f README && $lfs_pull"
clone_github="cd /tmp && rm -rf g && git clone -q --depth 1 $GITHUB_REPO g && test -f g/README"

echo "--- :linux: Distributions"
# <name> <base> <expected SSL_CERT_FILE>; @B@ is the bundle.
while read -r name base want; do
	client "$id:$name" "$base"
	got=$(sh_in "$id:$name" "git -c 'alias.e=!echo \"\$SSL_CERT_FILE\"' e")
	[[ $got == "${want//@B@/$B}" ]] || die "$name: SSL_CERT_FILE=$got, want $want"
	sh_in "$id:$name" "$clone_github"
	agent_job "https-$name"
	run_in "${job[@]}" "${creds[@]}" -e REPO=https://gitserver/auth/main.git \
		-e GIT_SSL_CAINFO=/test/ca.crt "$id:$name" /test/agent-checkout.sh
	pass "$name: SSL_CERT_FILE=$got, GitHub clone, agent checkout over HTTPS"
done <<'EOF'
alpine      alpine:3.24                                   /etc/ssl/certs/ca-certificates.crt
debian12    debian:bookworm-slim                          @B@/etc/ssl/cacert.pem
debian13    debian:trixie-slim                            @B@/etc/ssl/cacert.pem
debian13-ca buildpack-deps:trixie-curl                    /etc/ssl/certs/ca-certificates.crt
ubuntu2204  ubuntu:22.04                                  @B@/etc/ssl/cacert.pem
ubuntu2404  ubuntu:24.04                                  @B@/etc/ssl/cacert.pem
rocky9      rockylinux:9                                  /etc/pki/tls/certs/ca-bundle.crt
ubi9        registry.access.redhat.com/ubi9/ubi-minimal   /etc/pki/tls/certs/ca-bundle.crt
fedora42    fedora:42                                     /etc/ssl/certs/ca-certificates.crt
al2023      amazonlinux:2023                              /etc/ssl/certs/ca-certificates.crt
leap15      opensuse/leap:15.6                            /etc/ssl/ca-bundle.pem
busybox     busybox:1.37                                  @B@/etc/ssl/cacert.pem
EOF

echo "--- :lock: Private CA"
# The image's CA store: unknown CA fails, adding it the distro's way works,
# and public HTTPS keeps working.
# <client image> <command that adds /test/ca.crt to the store>
while read -r name add_ca; do
	out=$(sh_in "$id:$name" "{ $clone_private; } 2>&1" || true)
	[[ $out == *"certificate"* ]] || die "$name: clone with an unknown CA: $out"
	sh_in "$id:$name" "$add_ca && $clone_private && $clone_github"
	pass "$name: CA added to the image's store is trusted"
done <<'EOF'
debian13-ca cp /test/ca.crt /usr/local/share/ca-certificates/test.crt && update-ca-certificates >/dev/null 2>&1
rocky9      cp /test/ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust
alpine      cat /test/ca.crt >>/etc/ssl/certs/ca-certificates.crt
EOF

# User settings, in an image with no CA store (the bundled one is used).
c=$id:debian12
run_in -e SSL_CERT_FILE=/test/ca.crt "$c" "$clone_private"
pass "SSL_CERT_FILE set by the user"
run_in -e SSL_CERT_DIR=/certs "$c" "mkdir /certs && cp /test/ca.crt /certs/$CA_HASH.0 && $clone_private"
pass "SSL_CERT_DIR set by the user"
sh_in "$c" "git config --system http.sslCAInfo /test/ca.crt && $clone_private"
pass "http.sslCAInfo in /etc/gitconfig"
sh_in "$c" "git config --system http.https://gitserver/.sslCAInfo /test/ca.crt && $clone_private && $clone_github"
pass "per-URL http.<url>.sslCAInfo, other hosts unaffected"
run_in -e GIT_SSL_NO_VERIFY=1 "$c" "$clone_private"
pass "GIT_SSL_NO_VERIFY"

echo "--- :globe_with_meridians: HTTP proxy"
# Only the server's container resolves git.internal, so these clones work
# only through the proxy running there.
internal="cd /tmp && rm -rf r && git clone -q https://git.internal/main.git r && cd r && test -f README && $lfs_pull"
sh_in "$c" "! GIT_SSL_CAINFO=/test/ca.crt git ls-remote https://git.internal/main.git >/dev/null 2>&1"
run_in -e https_proxy=http://gitserver:8888 -e GIT_SSL_CAINFO=/test/ca.crt "$c" "$internal"
docker exec "$id-server" grep -q "git.internal" /var/log/tinyproxy.log ||
	die "the proxy did not see the request"
# Not "docker logs | grep -q": grep exits early and pipefail fails the check.
[[ $(docker logs "$id-server" 2>&1) == *"POST /main.git/info/lfs/objects/batch"* ]] ||
	die "the LFS server did not see a batch request"
pass "https_proxy"
run_in -e HTTPS_PROXY=http://gitserver:8888 -e GIT_SSL_CAINFO=/test/ca.crt "$c" "$internal"
pass "HTTPS_PROXY"
run_in -e GIT_SSL_CAINFO=/test/ca.crt "$c" "git config --system http.proxy http://gitserver:8888 && $internal"
pass "http.proxy"
run_in -e https_proxy=http://127.0.0.1:9 -e no_proxy=gitserver -e GIT_SSL_CAINFO=/test/ca.crt "$c" "$clone_private"
pass "no_proxy bypasses the proxy"

echo "--- :shield: safe.directory"
# /repo belongs to another user, as a checkout on a mounted volume often does.
setup="git init -q /repo && chown -R 1000:1000 /repo"
out=$(sh_in "$c" "$setup && git -C /repo status 2>&1" || true)
[[ $out == *"dubious ownership"* ]] || die "repo owned by another user: $out"
pass "a repo owned by another user is refused"
sh_in "$c" "$setup && git config --system --add safe.directory /repo && git -C /repo status >/dev/null"
pass "safe.directory in /etc/gitconfig"
sh_in "$c" "$setup && git config --global --add safe.directory '*' && git -C /repo status >/dev/null"
pass "safe.directory=* in the global config"
sh_in "$c" "$setup && git -c safe.directory=/repo -C /repo status >/dev/null"
pass "safe.directory with -c"
run_in -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
	"$c" "$setup && git -C /repo status >/dev/null"
pass "safe.directory with GIT_CONFIG_COUNT"
sh_in "$c" "$setup && git config -f /repo/.git/config safe.directory /repo && ! git -C /repo status >/dev/null 2>&1"
pass "safe.directory in the repo's own config is ignored"

echo "--- :key: Agent checkout over SSH"
# None of these images has an ssh client, so git can only use the bundled one.
ssh_setup='! command -v ssh >/dev/null
	mkdir -p ~/.ssh && cp /test/id_ed25519 /test/known_hosts ~/.ssh/
	chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519'
# git-lfs-authenticate sends git-lfs to the HTTPS server, so it needs the CA.
for name in debian12 rocky9 busybox; do
	agent_job "ssh-$name"
	run_in "${job[@]}" -e REPO=git@gitserver:/srv/git/main.git -e GIT_SSL_CAINFO=/test/ca.crt "$id:$name" \
		"$ssh_setup
		/test/agent-checkout.sh"
	pass "$name: agent checkout over SSH, default key and known_hosts"
done
# The agent sets GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
# and has no known_hosts. Plain "ssh" there still finds the bundled one, which
# must record the host key itself.
agent_job "ssh-accept-new"
run_in "${job[@]}" -e REPO=git@gitserver:/srv/git/main.git -e GIT_SSL_CAINFO=/test/ca.crt \
	-e 'GIT_SSH_COMMAND=ssh -i /tmp/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
	"$c" "install -m 600 /test/id_ed25519 /tmp/key && test ! -e ~/.ssh
	/test/agent-checkout.sh
	grep -q '^gitserver ssh-ed25519 ' ~/.ssh/known_hosts"
pass "agent checkout over SSH with GIT_SSH_COMMAND and accept-new"

echo "--- :gear: Runtime environments"
https_ca=(-e GIT_SSL_CAINFO=/test/ca.crt)
clone_sub="cd /tmp && rm -rf r && git clone -q --recurse-submodules $PRIVATE_REPO r && cd r && test -f sub/sub.txt && $lfs_pull"
run_in --user 12345:12345 "${https_ca[@]}" "$c" "$clone_sub"
pass "random UID with no passwd entry and no writable HOME"
run_in --read-only --tmpfs /tmp "${https_ca[@]}" "$c" "$clone_sub"
pass "read-only root filesystem"
run_in "${https_ca[@]}" "$c" "ln -s $B/bin/git /usr/local/bin/git
	export PATH=/usr/local/bin:/usr/bin:/bin
	test \"\$(git --exec-path)\" = $B/libexec/git-core
	$clone_sub"
pass "symlink to bin/git on PATH"
run_in "${https_ca[@]}" "$c" "cp -a $B '/opt/static git'
	export PATH='/opt/static git/bin:/usr/bin:/bin'
	test \"\$(git --exec-path)\" = '/opt/static git/libexec/git-core'
	git init -q /tmp/t && test -f /tmp/t/.git/hooks/pre-commit.sample
	$clone_sub"
pass "bundle path with a space"
for name in alpine debian12; do
	sh_in "$id:$name" "cd /tmp && env -i $B/bin/git clone -q --depth 1 $GITHUB_REPO e && test -f e/README"
	pass "$name: empty environment (no PATH, no HOME)"
done

echo "--- :hammer_and_wrench: Features"
for name in debian12 alpine; do
	sh_in "$id:$name" /test/features.sh
	pass "$name: features"
done

echo "+++ :white_check_mark: All matrix tests passed on $platform"
