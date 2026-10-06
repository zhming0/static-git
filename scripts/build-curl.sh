#!/bin/sh
# Build a static libcurl for git's HTTP transport and install it to /opt/curl.
# Usage: build-curl.sh <versions.env> <src-dir>
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
cd "$2"
tar xf "curl-${CURL_VERSION}.tar.xz"
cd "curl-${CURL_VERSION}"

# No compiled-in CA bundle or CA path. With --with-ca-fallback curl then uses
# OpenSSL's default store, which honours SSL_CERT_FILE and SSL_CERT_DIR. git's
# http.sslCAInfo and GIT_SSL_CAINFO set the CA file explicitly, so they still
# win over that.
#
# Everything git does not need is off, which also keeps the static link chain
# short: only http(s), no brotli/zstd/idn2/psl/ldap/ssh.
./configure \
	--prefix=/opt/curl \
	--disable-shared \
	--enable-static \
	--with-openssl \
	--with-nghttp2 \
	--with-zlib \
	--without-ca-bundle \
	--without-ca-path \
	--with-ca-fallback \
	--without-brotli \
	--without-zstd \
	--without-libidn2 \
	--without-libpsl \
	--without-libssh \
	--without-libssh2 \
	--without-librtmp \
	--without-libgsasl \
	--disable-ldap \
	--disable-ldaps \
	--disable-dict \
	--disable-file \
	--disable-ftp \
	--disable-gopher \
	--disable-imap \
	--disable-ipfs \
	--disable-mqtt \
	--disable-pop3 \
	--disable-rtsp \
	--disable-smb \
	--disable-smtp \
	--disable-telnet \
	--disable-tftp \
	--disable-websockets \
	--disable-docs \
	--disable-manual

make -j"$(nproc)" -C lib
make -C lib install
make -C include install
# libcurl.pc and curl-config are generated at the top level.
install -Dm644 libcurl.pc /opt/curl/lib/pkgconfig/libcurl.pc
install -Dm755 curl-config /opt/curl/bin/curl-config
