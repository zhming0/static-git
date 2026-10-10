#!/bin/sh
# Download the upstream source tarballs at the versions in versions.env and
# check each one's OpenPGP signature against its project's release key.
# Usage: fetch-sources.sh <versions.env> <keys-dir> <dest-dir>
#
# The release keys are pinned in <keys-dir> instead of a checksum per version,
# so a version bump is only a change to versions.env. Each tarball must be
# signed by its own project's key, with the fingerprint given below.
# Needs curl, gpg, gpgv and xz.
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
keys=$(cd "$2" && pwd)
dest=$3
mkdir -p "$dest"
cd "$dest"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME

download() {
	echo "fetching $1"
	curl -fsSL --retry 3 -o "${1##*/}" "$1"
}

# verify <key-name> <fingerprint> <signature> <signed-file, or - for stdin>
verify() {
	# gpgv reads only binary keyrings; the keys are stored armored so they
	# can be read in review.
	gpg --batch --quiet --dearmor <"$keys/$1.asc" >"$GNUPGHOME/$1.gpg"
	gpgv --keyring "$GNUPGHOME/$1.gpg" --status-fd 3 "$3" "$4" 3>"$GNUPGHOME/status"
	# The last field of VALIDSIG is the primary key's fingerprint, also when
	# a subkey made the signature.
	signer=$(awk '$2 == "VALIDSIG" { print $NF }' "$GNUPGHOME/status")
	if [ "$signer" != "$2" ]; then
		echo "$3: signed by '$signer', want $2" >&2
		exit 1
	fi
}

# git signs the uncompressed tar, so the signature is checked over xz's output.
git=https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}
download "$git.tar.xz"
download "$git.tar.sign"
xz -dc "git-${GIT_VERSION}.tar.xz" |
	verify git 96E07AF25771955980DAD10020D04E5A713660A7 "git-${GIT_VERSION}.tar.sign" -

curl=https://curl.se/download/curl-${CURL_VERSION}.tar.xz
download "$curl"
download "$curl.asc"
verify curl 27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2 "${curl##*/}.asc" "${curl##*/}"

openssh=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz
download "$openssh"
download "$openssh.asc"
verify openssh 7168B983815A5EEF59A4ADFD2A3F414E736060BA "${openssh##*/}.asc" "${openssh##*/}"

rm -rf "$GNUPGHOME" ./*.sign ./*.asc
# Logged so the build output records exactly which files were used.
sha256sum ./*
