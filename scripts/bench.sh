#!/usr/bin/env bash
# Compare the bundle's git with distribution gits on the same machine.
#
# Usage: bench.sh <static-git-*.tar.gz> [output.md]
#
# Native platform only: timings under QEMU mean nothing. Each bench image is a
# distribution with its own git and the bundle; test/bench-run.sh times both,
# working in a tmpfs so the disk is not measured. Apart from one clone from
# GitHub, everything runs on a local bare clone of git/git. Writes a Markdown
# report (default: bench.md).
set -euo pipefail

tarball=$1
report=${2:-bench.md}
case "$(uname -m)" in
x86_64) platform=linux/amd64 ;;
aarch64 | arm64) platform=linux/arm64 ;;
*) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
here=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=scripts/test-lib.sh
. "$here/scripts/test-lib.sh"

cp "$here/test/bench-run.sh" "$work/"
docker volume create --label "$id" "$id-src" >/dev/null
docker volume create --label "$id" "$id-out" >/dev/null

echo "--- :package: $(basename "$tarball")"
cat "$work/bundle/VERSIONS"

echo "--- :git: Cloning git/git (untimed)"
image "$id:alpine" alpine:3.24 <<'EOF'
RUN apk add --no-cache git hyperfine jq
COPY bench-run.sh /usr/local/bin/
EOF
docker run --rm -v "$id-src:/src" "$id:alpine" \
	"$B/bin/git" clone -q --bare https://github.com/git/git.git /src/git.git

image "$id:debian" debian:trixie-slim <<'EOF'
RUN apt-get update -qq && apt-get install -qq -y --no-install-recommends ca-certificates git hyperfine jq >/dev/null
COPY bench-run.sh /usr/local/bin/
EOF

for distro in alpine debian; do
	echo "--- :stopwatch: static vs $distro git"
	docker run --rm -v "$id-src:/src:ro" -v "$id-out:/out" --tmpfs /work:exec,size=4g \
		"$id:$distro" bench-run.sh "$distro"
done

# Nothing on this host can read the volume directly if the daemon is remote.
results=$(docker run --rm -v "$id-out:/out" "$id:alpine" sh -c '
	for f in alpine debian; do
		echo "### static vs $f ($(cat /out/$f.version))"
		echo
		echo "| | static (ms) | $f (ms) | static / $f |"
		echo "|---|---:|---:|---:|"
		cat /out/$f.md
		echo
	done')

{
	echo "## Benchmark: $(sed -n 's/^git=//p' "$work/bundle/VERSIONS") ($platform, $(nproc) CPUs)"
	echo
	echo "Mean ± standard deviation from hyperfine. Below 1 in the last column means the"
	echo "bundle's git is faster."
	echo
	echo "$results"
} >"$report"
cat "$report"
