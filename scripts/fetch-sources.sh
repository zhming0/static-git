#!/bin/sh
# Download the upstream source tarballs pinned in versions.env and check their
# sha256. Usage: fetch-sources.sh <versions.env> <dest-dir>
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
dest=$2
mkdir -p "$dest"
cd "$dest"

fetch() {
	url=$1 sha=$2 file=${1##*/}
	echo "fetching $url"
	curl -fsSL --retry 3 -o "$file" "$url"
	echo "$sha  $file" | sha256sum -c -
}

fetch "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" "$GIT_SHA256"
fetch "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" "$CURL_SHA256"
fetch "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" "$OPENSSH_SHA256"
