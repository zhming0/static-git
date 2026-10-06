#!/bin/sh
# Build a fully static git against the libcurl in /opt/curl and install it to
# <destdir>/usr. Usage: build-git.sh <versions.env> <src-dir> <destdir>
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
cd "$2"
destdir=$3
tar xf "git-${GIT_VERSION}.tar.xz"
cd "git-${GIT_VERSION}"

export PKG_CONFIG_PATH=/opt/curl/lib/pkgconfig
curl_libs=$(pkg-config --static --libs libcurl)
curl_cflags=$(pkg-config --static --cflags libcurl)

# RUNTIME_PREFIX makes git find its exec-path and templates relative to its
# own binary, so the bundle can live anywhere. sysconfdir stays absolute so
# git still reads the image's /etc/gitconfig.
#
# Install must not use INSTALL_SYMLINKS: it would make libexec/git-core/git a
# symlink to bin/git, and bin/git is the launcher, so git would exec itself
# forever.
#
# The musl knobs (NO_REGEX, NO_SYS_POLL_H, ICONV_OMITS_BOM) match Alpine's
# own git package.
cat >config.mak <<EOF
prefix = /usr
gitexecdir = libexec/git-core
template_dir = share/git-core/templates
sysconfdir = /etc
RUNTIME_PREFIX = YesPlease

NO_PERL = YesPlease
NO_PYTHON = YesPlease
NO_TCLTK = YesPlease
NO_GETTEXT = YesPlease
NO_OPENSSL = YesPlease
USE_LIBPCRE2 = YesPlease

NO_REGEX = YesPlease
NO_SYS_POLL_H = 1
ICONV_OMITS_BOM = Yes

CFLAGS = -O2
LDFLAGS = -static
CURL_CONFIG = /opt/curl/bin/curl-config
CURL_CFLAGS = $curl_cflags
CURL_LDFLAGS = $curl_libs
EOF

# Strip in the build tree: install then hardlinks the built-ins, and stripping
# afterwards would replace each hardlink with its own copy.
make -j"$(nproc)" all strip
make install DESTDIR="$destdir"
