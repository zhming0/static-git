#!/bin/sh
# Build a static OpenSSH client (ssh only) and copy it to <out>.
# Usage: build-openssh.sh <versions.env> <src-dir> <out>
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
cd "$2"
out=$3
tar xf "openssh-${OPENSSH_VERSION}.tar.gz"
cd "openssh-${OPENSSH_VERSION}"

# OpenSSL stays linked in so RSA and ECDSA keys keep working. sysconfdir is
# /etc/ssh, so the image's ssh_config and the user's ~/.ssh are read as usual.
# FIDO keys need an ssh-sk-helper we do not ship, so they are off.
./configure \
	--prefix=/usr \
	--sysconfdir=/etc/ssh \
	--with-ldflags=-static \
	--without-pam \
	--without-kerberos5 \
	--without-selinux \
	--without-libedit \
	--disable-security-key

make -j"$(nproc)" ssh
strip ssh
install -Dm755 ssh "$out/ssh"
