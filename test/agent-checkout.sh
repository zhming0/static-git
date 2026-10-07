#!/bin/sh
# Run the git commands the Buildkite agent's default checkout runs, against
# the matrix test's git server, inside a test image. POSIX sh, so it works
# with busybox ash and dash.
#
# Env: REPO       main.git URL (HTTPS or SSH)
#      MAIN_SHA   tip of main
#      PR_SHA     tip of refs/pull/1/head
#      JOB        unique name for the tag and branch pushed back
#
# Flags are the agent's defaults: clone -v, clean -ffxdq, fetch -v --prune,
# checkout -f (see buildkite/agent internal/job/checkout.go).
set -eu

: "${REPO:?}" "${MAIN_SHA:?}" "${PR_SHA:?}" "${JOB:?}"
export GIT_TERMINAL_PROMPT=0
root=$(mktemp -d)
log=$root/log

# Quiet unless something fails.
run() {
	if ! "$@" >>"$log" 2>&1; then
		cat "$log" >&2
		echo "agent-checkout: failed: $*" >&2
		exit 1
	fi
}

submodules() {
	run git submodule sync --recursive
	run git submodule update --init --recursive --force
	run git submodule foreach --recursive "git reset --hard"
}

clean() {
	run git clean -ffxdq
	run git submodule foreach --recursive "git clean -ffxdq"
}

# Job 1: a branch build at the tip of main, in a new checkout dir.
mkdir "$root/checkout" && cd "$root/checkout"
run git clone -v -- "$REPO" .
run git clean -ffxdq
run git fetch -v --prune -- origin main
run git checkout -f FETCH_HEAD
submodules
clean
test "$(git rev-parse HEAD)" = "$MAIN_SHA"
test -f sub/sub.txt
git --no-pager log -1 HEAD -s --no-color --format='%H%n%an%n%ae%n%s' | grep -qx "Second commit"

# Job 2: a pull request build at a commit on no branch, reusing the dirty
# checkout dir from job 1.
echo dirty >>README
echo junk >untracked.txt
echo junk >sub/untracked.txt
clean
run git fetch -v --prune -- origin refs/pull/1/head
run git checkout -f "$PR_SHA"
submodules
clean
test "$(git rev-parse HEAD)" = "$PR_SHA"
test -f pr.txt
test ! -e untracked.txt
test ! -e sub/untracked.txt
git diff --quiet

# Job 3: git mirrors (BUILDKITE_GIT_MIRRORS_PATH): a mirror clone, updated,
# then a checkout that borrows its objects.
run git clone --mirror -v -- "$REPO" "$root/mirror"
run git --git-dir="$root/mirror" fetch -v --prune origin
mkdir "$root/mirrored" && cd "$root/mirrored"
run git clone -v --reference "$root/mirror" -- "$REPO" .
run git fetch -v --prune -- origin "$MAIN_SHA"
run git checkout -f "$MAIN_SHA"
run git submodule update --init --recursive --force
test -f .git/objects/info/alternates
test -f sub/sub.txt

# Job 4: sparse checkout with a blobless partial clone
# (BUILDKITE_GIT_SPARSE_CHECKOUT_PATHS).
mkdir "$root/sparse" && cd "$root/sparse"
run git clone -v --filter=blob:none --sparse --no-checkout -- "$REPO" .
run git sparse-checkout set --cone src
run git fetch -v --prune -- origin main
run git checkout -f FETCH_HEAD
test -f src/main.c
test ! -e docs/index.md

# Job 5: a shallow clone, then push a tag and a branch back.
mkdir "$root/shallow" && cd "$root/shallow"
run git clone -v --depth 1 --branch main -- "$REPO" .
test "$(git rev-list --count HEAD)" = 1
run git -c user.name=ci -c user.email=ci@example.com tag -a "ci-$JOB" -m ci
run git push origin "ci-$JOB" "HEAD:refs/heads/ci-$JOB"
run git ls-remote --exit-code origin "refs/tags/ci-$JOB" "refs/heads/ci-$JOB"

rm -rf "$root"
