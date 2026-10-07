# shellcheck shell=bash
# Helpers shared by smoke-test.sh and matrix-test.sh. Source it after setting
# $tarball and $platform.
#
# Needs only docker. The bundle is copied into each test image instead of
# bind-mounted, so the tests also work when the docker daemon is not on this
# host (hosted agents). A non-native platform needs QEMU binfmt handlers.

: "${tarball:?}" "${platform:?}"

# Where test images get the bundle.
B=/opt/static-git
# Prefix for everything the test creates: image tags, containers, networks.
id=sg-$(basename "$0" .sh)-$$
# Build context for test images. bundle/ holds the unpacked tarball.
work=$(mktemp -d)
# Docker network for sh_in/run_in.
net=bridge

cleanup() {
	docker ps -aq --filter "label=$id" | xargs -r docker rm -f >/dev/null 2>&1 || true
	docker network ls -q --filter "label=$id" | xargs -r docker network rm >/dev/null 2>&1 || true
	docker volume ls -q --filter "label=$id" | xargs -r docker volume rm >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

pass() { echo "ok: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bundle"
tar -C "$work/bundle" -xzf "$tarball"

# image <tag> <base>: build <tag> from <base> with the bundle at $B. Extra
# Dockerfile lines can follow on stdin. --load matters with a remote buildx
# builder (hosted agents), which otherwise keeps the image to itself; for the
# same reason <base> must be a registry image, not one built here.
image() {
	local tag=$1 base=$2
	{
		echo "FROM $base"
		echo "COPY bundle/ $B/"
		cat
	} >"$work/Dockerfile"
	docker buildx build -q --load --platform "$platform" -t "$tag" -f "$work/Dockerfile" "$work" >/dev/null
}

# run_in [docker run options...] <tag> <command>: run a shell command in
# <tag> on $net, with the bundle's git first on PATH.
run_in() {
	local tag=${*: -2:1} cmd=${*: -1}
	local opts=("${@:1:$#-2}")
	docker run --rm --platform "$platform" --network "$net" \
		-e "PATH=$B/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		"${opts[@]}" "$tag" sh -ec "$cmd"
}

# sh_in <tag> <command>: run_in without extra options.
sh_in() {
	run_in "$1" "$2"
}

# new_network: create a labelled docker network named $id and use it.
new_network() {
	docker network create --label "$id" "$id" >/dev/null
	net=$id
}

# wait_ready <container>: wait up to 60s for <container> to create /ready.
wait_ready() {
	for _ in $(seq 1 60); do
		docker exec "$1" test -f /ready 2>/dev/null && return 0
		sleep 1
	done
	docker logs "$1" >&2
	die "$1 did not start"
}
