#!/usr/bin/env bash
# Smoke-test one bundle tarball in real images.
#
# Usage: smoke-test.sh <static-git-*.tar.gz> <platform, e.g. linux/arm64>
#
# Needs only docker (see test-lib.sh).
#
# Checks:
#   - basics: version, templates, /etc/gitconfig, PATH order
#   - every git binary uses mimalloc
#   - HTTPS clone with no config, in images with and without a CA store
#   - SSH clone with RSA, ECDSA and ed25519 keys, using the bundled ssh
#   - an ssh already in the image wins over the bundled one
set -euo pipefail

tarball=$1
platform=$2

# shellcheck source=scripts/test-lib.sh
. "$(dirname "$0")/test-lib.sh"

HTTPS_REPO=https://github.com/octocat/Hello-World.git

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

# Every git binary must use mimalloc instead of musl's malloc (see
# build-git.sh). With MIMALLOC_VERBOSE=1, mimalloc prints its version at start.
# Hardlinks to one binary are checked once.
# shellcheck disable=SC2016  # expanded in the container
out=$(sh_in "$id:alpine" "cd $B/libexec/git-core"'
	for f in *; do
		[ "$(head -c 4 "$f" | tail -c 3)" = ELF ] || continue
		i=$(stat -c %i "$f")
		case " $seen " in *" $i "*) continue ;; esac
		seen="$seen $i"
		MIMALLOC_VERBOSE=1 ./"$f" --version </dev/null 2>&1 >/dev/null | grep -q "^mimalloc: v" ||
			{ echo "$f does not use mimalloc" >&2; exit 1; }
		printf "%s " "$f"
	done')
[[ $out == *"git "* && $out == *git-remote-* ]] || die "mimalloc check missed git or the HTTP helper: $out"
pass "mimalloc in every git binary: ${out% }"

echo "--- :lock: HTTPS clone with no config"
# <name> <base> <expected SSL_CERT_FILE>; "-" means the image has no shell.
while read -r name base want; do
	image "$id:$name" "$base" </dev/null
	if [[ $want == - ]]; then
		# No shell: run git directly, clone into a volume, check it from busybox.
		docker volume rm "$id" >/dev/null 2>&1 || true
		docker volume create --label "$id" "$id" >/dev/null
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
new_network
docker run -d --label "$id" --name "$id-sshd" --network "$id" --network-alias sshd alpine:3.24 sh -ec '
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
wait_ready "$id-sshd"
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
