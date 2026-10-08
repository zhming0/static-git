#!/bin/sh
# Build a static git-lfs for <goos>/<goarch>. Runs on the build host with Go
# and cross-compiles, like the launcher.
#
# Usage: build-git-lfs.sh <versions.env> <src-dir> <out-file> <goos> <goarch>
#
# Go modules are downloaded during the build and checked against git-lfs's
# go.sum, as Alpine's package does.
set -eu

# shellcheck source=/dev/null  # versions.env, passed by the caller
. "$1"
cd "$2"
out=$3
goos=$4
goarch=$5
tar xzf "git-lfs-v${GIT_LFS_VERSION}.tar.gz"
cd "git-lfs-${GIT_LFS_VERSION}"

# Use the pinned Go, never a toolchain named in go.mod.
export GOTOOLCHAIN=local

# Turn docs/man into the text "git lfs help <command>" prints. This runs a Go
# program, so it must build for the host, not the target. Translations are
# left out, as they are for git.
go generate ./commands

# cgo off makes the binary static and uses Go's own DNS resolver, which reads
# /etc/hosts and /etc/resolv.conf as musl does. GitCommit is what
# "git lfs version" prints after the version; the Makefile sets it the same way.
CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath \
	-ldflags="-s -w -X github.com/git-lfs/git-lfs/v3/config.GitCommit=v${GIT_LFS_VERSION}" \
	-o "$out" .
