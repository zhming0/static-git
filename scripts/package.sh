#!/bin/sh
# Assemble the bundle and write the tarball, its checksum and a size report.
#
# Usage: package.sh <versions.env> <git-destdir> <ssh-dir> <launcher> <dist>
#
# Bundle layout (paths are relative to wherever the bundle is unpacked):
#
#   bin/git                     launcher
#   libexec/git-core/           real git and its helpers
#   share/git-core/templates/
#   fallback/bin/ssh            static OpenSSH client, last on PATH
#   etc/ssl/cacert.pem          CA bundle, used only if the image has none
#   VERSIONS                    every component version
#
# ssh must never go into libexec/git-core: git prepends that directory to
# PATH, so an ssh there would override the image's ssh.
# shellcheck disable=SC3040  # busybox ash supports pipefail
set -eu -o pipefail

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
git_destdir=$2
ssh_dir=$3
launcher=$4
dist=$5

case "$(uname -m)" in
x86_64) arch=amd64 ;;
aarch64) arch=arm64 ;;
*) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

bundle=$(mktemp -d)

install -Dm755 "$launcher" "$bundle/bin/git"
mkdir -p "$bundle/libexec" "$bundle/share"
cp -a "$git_destdir/usr/libexec/git-core" "$bundle/libexec/"
cp -a "$git_destdir/usr/share/git-core" "$bundle/share/"
install -Dm755 "$ssh_dir/ssh" "$bundle/fallback/bin/ssh"
install -Dm644 /etc/ssl/certs/ca-certificates.crt "$bundle/etc/ssl/cacert.pem"

# imap-send belongs with send-email, which is out of scope, and it is one more
# ~10 MB copy of libcurl and OpenSSL.
rm "$bundle/libexec/git-core/git-imap-send"

# Nothing may point outside the bundle. In particular libexec/git-core/git
# must be the real git, never a link back to bin/git (the launcher).
if [ -n "$(find "$bundle" -type l)" ]; then
	find "$bundle" -type l -exec ls -l {} + >&2
	echo "the bundle must not contain symlinks" >&2
	exit 1
fi

# Every ELF file must be static. A dynamic one would fail in scratch or
# distroless images, so stop the build here instead.
find "$bundle" -type f | while read -r f; do
	info=$(file -b "$f")
	case "$info" in
	ELF*)
		case "$info" in
		*"statically linked"* | *"static-pie linked"*) ;;
		*) echo "not static: $f: $info" >&2; exit 1 ;;
		esac
		;;
	esac
done

# Version of an installed Alpine package, from the apk database.
apkver() {
	awk -v p="$1" '/^P:/ { name = substr($0, 3) } /^V:/ && name == p { print substr($0, 3) }' \
		/lib/apk/db/installed
}

cat >"$bundle/VERSIONS" <<EOF
arch=linux/$arch
alpine=$(cat /etc/alpine-release)
git=$GIT_VERSION
curl=$CURL_VERSION
openssh=$OPENSSH_VERSION
openssl=$(apkver openssl-libs-static)
zlib=$(apkver zlib-static)
expat=$(apkver expat-static)
pcre2=$(apkver pcre2-static)
nghttp2=$(apkver nghttp2-static)
mimalloc=$(apkver mimalloc2-dev)
ca-certificates=$(apkver ca-certificates-bundle)
EOF

name="static-git-${GIT_VERSION}-linux-${arch}"
mkdir -p "$dist"
# Hardlinks are kept: the git built-ins (git-upload-pack, ...) are ~140 links
# to one binary.
tar -C "$bundle" --sort=name --owner=0 --group=0 --numeric-owner -cf - . |
	gzip -9n >"$dist/$name.tar.gz"
(cd "$dist" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")

{
	echo "# $name"
	echo
	cat "$bundle/VERSIONS"
	echo
	echo "## Sizes (bytes)"
	echo
	printf '%10d  %s\n' "$(wc -c <"$dist/$name.tar.gz")" "tarball (gzip)"
	printf '%10d  %s\n' "$(du -sb "$bundle" | cut -f1)" "unpacked"
	# Files over 100 KB, each hardlinked binary once with its link count.
	(cd "$bundle" && find . -type f -size +100k -exec stat -c '%i %s %h %n' {} + |
		sort -k4 | awk '!seen[$1]++ {
			printf "%10d  %s%s\n", $2, substr($4, 3), ($3 > 1 ? " (" $3 " links)" : "")
		}')
} >"$dist/$name.sizes.txt"

cat "$dist/$name.sizes.txt"
