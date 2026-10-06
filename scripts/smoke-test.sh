#!/usr/bin/env bash
# Smoke-test one bundle tarball in real images.
#
# Usage: smoke-test.sh <static-git-*.tar.gz> <platform, e.g. linux/arm64>
#
# Needs only docker. The bundle is copied into each test image instead of
# bind-mounted, so this also works when the docker daemon is not on this host.
# A non-native platform needs QEMU binfmt handlers.
#
# Checks:
#   - basics: version, templates, /etc/gitconfig, PATH order
#   - HTTPS clone with no config, in images with and without a CA store
#   - SSH clone with RSA, ECDSA and ed25519 keys, using the bundled ssh
#   - an ssh already in the image wins over the bundled one
set -euo pipefail

tarball=$1
platform=$2

B=/opt/static-git
HTTPS_REPO=https://github.com/octocat/Hello-World.git
id=sg-smoke-$$
work=$(mktemp -d)

cleanup() {
	docker rm -f "$id-sshd" >/dev/null 2>&1 || true
	docker network rm "$id" >/dev/null 2>&1 || true
	docker volume rm "$id" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "ok: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bundle"
tar -C "$work/bundle" -xzf "$tarball"

# Build <tag> from <base> with the bundle at $B. Extra Dockerfile lines can
# follow on stdin. --load matters with a remote buildx builder (hosted agents),
# which otherwise keeps the image to itself; for the same reason <base> must be
# a registry image, not one built here.
image() {
	local tag=$1 base=$2
	{
		echo "FROM $base"
		echo "COPY bundle/ $B/"
		cat
	} >"$work/Dockerfile"
	docker buildx build -q --load --platform "$platform" -t "$tag" -f "$work/Dockerfile" "$work" >/dev/null
}

# Run a shell command in <tag>, with the bundle's git first on PATH. Set net
# to run on that docker network.
net=bridge
sh_in() {
	local tag=$1
	shift
	docker run --rm --platform "$platform" --network "$net" \
		-e "PATH=$B/bin:/usr/local/bin:/usr/bin:/bin" "$tag" sh -ec "$*"
}

echo "--- :package: $(basename "$tarball") on $platform"
cat "$work/bundle/VERSIONS"

echo "--- :mag: Basics (alpine)"
image "$id:alpine" alpine:3.24 </dev/null

out=$(sh_in "$id:alpine" 'git --version')
[[ $out == "git version "* ]] || die "git --version: $out"
pass "$out"

# Templates come from the bundle (RUNTIME_PREFIX).
sh_in "$id:alpine" 'cd /tmp && git init -q r && test -f r/.git/hooks/pre-commit.sample'
pass "git init finds the bundled templates"

# The system config is still the image's /etc/gitconfig (absolute sysconfdir).
out=$(sh_in "$id:alpine" 'git config --system safe.directory /srv/x && git config --show-origin --system --get safe.directory')
[[ $out == "file:/etc/gitconfig"*"/srv/x" ]] || die "system config origin: $out"
pass "system config is /etc/gitconfig"

# git puts libexec/git-core first on a child's PATH, which is why ssh must not
# live there. The launcher's fallback dir must be last.
out=$(sh_in "$id:alpine" "git -c 'alias.p=!echo \"\$PATH\"' p")
[[ $out == "$B/libexec/git-core:"* ]] || die "child PATH does not start with libexec/git-core: $out"
[[ $out == *":$B/fallback/bin" ]] || die "child PATH does not end with fallback/bin: $out"
pass "child PATH: libexec/git-core first, fallback/bin last"

echo "--- :lock: HTTPS clone with no config"
# <name> <base> <expected SSL_CERT_FILE>; "-" means the image has no shell.
while read -r name base want; do
	image "$id:$name" "$base" </dev/null
	if [[ $want == - ]]; then
		# No shell: run git directly, clone into a volume, check it from busybox.
		docker volume rm "$id" >/dev/null 2>&1 || true
		docker run --rm --platform "$platform" -v "$id:/work" -e HOME=/work \
			--entrypoint "$B/bin/git" "$id:$name" clone -q --depth 1 "$HTTPS_REPO" /work/repo
		docker run --rm -v "$id:/work" busybox:1.37 test -f /work/repo/README
		pass "$name: HTTPS clone"
	else
		got=$(sh_in "$id:$name" "git -c 'alias.e=!echo \"\$SSL_CERT_FILE\"' e")
		[[ $got == "${want//@B@/$B}" ]] || die "$name: SSL_CERT_FILE=$got, want $want"
		sh_in "$id:$name" "cd /tmp && git clone -q --depth 1 $HTTPS_REPO repo && test -f repo/README"
		pass "$name: HTTPS clone with SSL_CERT_FILE=$got"
	fi
done <<'EOF'
alpine alpine:3.24 /etc/ssl/certs/ca-certificates.crt
debian debian:bookworm-slim @B@/etc/ssl/cacert.pem
busybox busybox:1.37 @B@/etc/ssl/cacert.pem
distroless gcr.io/distroless/static-debian12 -
scratch scratch -
EOF

echo "--- :lock: CA precedence (busybox, no system store)"
# Without the launcher nothing points at a CA store, so this proves libcurl
# has no CA path compiled in and the clones above used SSL_CERT_FILE.
sh_in "$id:busybox" "! $B/libexec/git-core/git clone -q --depth 1 $HTTPS_REPO /tmp/r 2>/dev/null"
pass "real git without the launcher has no CA store"
# An explicit CA file from the user wins over the launcher's SSL_CERT_FILE.
sh_in "$id:busybox" "! GIT_SSL_CAINFO=/etc/passwd git clone -q --depth 1 $HTTPS_REPO /tmp/r 2>/dev/null"
sh_in "$id:busybox" "! git -c http.sslCAInfo=/etc/passwd clone -q --depth 1 $HTTPS_REPO /tmp/r 2>/dev/null"
pass "GIT_SSL_CAINFO and http.sslCAInfo win over SSL_CERT_FILE"

echo "--- :key: SSH clone with the bundled ssh"
# The server runs natively; only the client is the platform under test.
docker network create "$id" >/dev/null
net=$id
docker run -d --name "$id-sshd" --network "$id" --network-alias sshd alpine:3.24 sh -ec '
	apk add -q openssh-server openssh-keygen git
	ssh-keygen -A
	adduser -D -s /bin/sh git
	echo "git:*" | chpasswd -e
	mkdir -p /keys ~git/.ssh
	for t in rsa ecdsa ed25519; do
		ssh-keygen -q -t $t -N "" -C $t -f /keys/id_$t
		cat /keys/id_$t.pub >>~git/.ssh/authorized_keys
	done
	git init -q --bare -b main /srv/repo.git
	git -C /tmp init -q -b main w
	git -C /tmp/w -c user.name=t -c user.email=t@t commit -q --allow-empty -m hello
	git -C /tmp/w push -q /srv/repo.git main
	chown -R git:git ~git /srv/repo.git
	chmod 700 ~git/.ssh
	touch /ready
	exec /usr/sbin/sshd -D -e
' >/dev/null
for _ in $(seq 1 60); do
	docker exec "$id-sshd" test -f /ready 2>/dev/null && break
	sleep 1
done
docker exec "$id-sshd" test -f /ready || { docker logs "$id-sshd" >&2; die "sshd did not start"; }
for t in rsa ecdsa ed25519; do
	docker exec "$id-sshd" cat /keys/id_$t >"$work/id_$t"
done

# debian-slim has no ssh, so git can only find the bundled one.
image "$id:ssh-client" debian:bookworm-slim <<EOF
COPY id_rsa id_ecdsa id_ed25519 /keys/
RUN ! command -v ssh
EOF

clone_ssh() {
	local tag=$1 key=$2
	sh_in "$tag" "
		mkdir -p ~/.ssh && cp /keys/id_$key ~/.ssh/ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_$key
		printf 'Host sshd\n  IdentityFile ~/.ssh/id_$key\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n' >~/.ssh/config
		cd /tmp && git clone -q git@sshd:/srv/repo.git r && git -C r log --format=%s | grep -qx hello
		[ ! -f /tmp/ssh.log ] || cat /tmp/ssh.log
	"
}

for t in rsa ecdsa ed25519; do
	clone_ssh "$id:ssh-client" $t
	pass "SSH clone with $t key"
done

echo "--- :key: An ssh already in the image wins"
# A logging ssh on the image's PATH stands in for the image's own client.
image "$id:ssh-wrapper" debian:bookworm-slim <<EOF
COPY id_rsa id_ecdsa id_ed25519 /keys/
RUN printf '#!/bin/sh\necho image-ssh >>/tmp/ssh.log\nexec $B/fallback/bin/ssh "\$@"\n' >/usr/local/bin/ssh && chmod +x /usr/local/bin/ssh
EOF
out=$(clone_ssh "$id:ssh-wrapper" ed25519)
[[ $out == *image-ssh* ]] || die "the image's ssh was not used"
pass "image ssh used over the bundled one"

echo "+++ :white_check_mark: All smoke tests passed on $platform"
