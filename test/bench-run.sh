#!/bin/sh
# Time the bundle's git against the image's own git with hyperfine, inside a
# bench image (see scripts/bench.sh). POSIX sh.
#
# Usage: bench-run.sh <label for the image's git>
#
# Needs: /src/git.git (a bare clone of git/git), hyperfine and jq, a writable
# /work (tmpfs, so disk speed is not measured) and /out for results.
# Writes /out/<label>.md, one Markdown table row per benchmark, and
# /out/<label>.version.
set -eu

label=$1
static=/opt/static-git/bin/git
distro=$(command -v -p git)
src=/src/git.git
w=/work
md=/out/$label.md

"$distro" --version | sed 's/^git version /git /' >"/out/$label.version"
: >"$md"

# Untimed setup, done with the bundle's git: a worktree at v2.54.0.
"$static" clone -q --no-checkout "$src" "$w/wt"
"$static" -C "$w/wt" checkout -q v2.54.0

# bench <name> [hyperfine options...] <command with {git}>
# Runs <command> once with each git and appends a row to $md:
#   | name | static mean ± sd | distro mean ± sd | static / distro |
bench() {
	name=$1
	shift
	hyperfine --style basic -L git "${bench_static:-$static},$distro" \
		--export-json "$w/$name.json" "$@" >&2
	jq -r --arg name "$name" '
		def ms: . * 1000 | if . < 10 then (. * 100 | round / 100) else round end;
		.results as [$s, $d]
		| "| \($name) | \($s.mean | ms) ± \($s.stddev | ms) | \($d.mean | ms) ± \($d.stddev | ms) | \($s.mean / $d.mean * 100 | round / 100) |"
	' "$w/$name.json" >>"$md"
}

# What an agent's first checkout of a large repo does. Includes the network,
# so it is noisy, but index-pack runs while the pack downloads, so CPU speed
# still shows.
bench "clone --bare from GitHub" -r 3 -p "rm -rf $w/c.git" \
	"{git} clone -q --bare https://github.com/git/git.git $w/c.git"
# The same pack-objects/index-pack work with no network.
bench "clone --bare --no-local" -r 3 -p "rm -rf $w/c.git" \
	"{git} clone -q --bare --no-local $src $w/c.git"
# Rewrites ~3,000 files.
bench "checkout v2.30.0 -> v2.54.0" -r 5 -p "{git} -C $w/wt checkout -q -f v2.30.0" \
	"{git} -C $w/wt checkout -q -f v2.54.0"
# Files written in the same second as the index are "racily clean", and
# status re-reads them until the index is rewritten. Settle that first, or
# the first git timed pays for it.
sleep 2
"$static" -C "$w/wt" update-index -q --really-refresh
bench "status" -N -w 3 -r 30 "{git} -C $w/wt status --porcelain"
bench "log --oneline (all history)" -w 1 -r 5 "{git} -C $src log --oneline v2.54.0"
bench "diff --stat v2.30.0 v2.54.0" -w 1 -r 5 "{git} -C $w/wt diff --stat v2.30.0 v2.54.0"
bench "blame Makefile" -w 1 -r 5 "{git} -C $w/wt blame -s Makefile"
bench "grep 'static int'" -w 2 -r 10 "{git} -C $w/wt grep -c 'static int'"
# Start-up cost, with no shell in between: through the launcher, then the
# real git directly, which shows what the launcher's extra exec costs.
bench "--version" -N -w 20 -r 300 "{git} --version"
bench_static=/opt/static-git/libexec/git-core/git \
	bench "--version (static without launcher)" -N -w 20 -r 300 "{git} --version"
