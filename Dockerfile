# syntax=docker/dockerfile:1

# Builds the static-git bundle for one platform. The final stage holds only the
# tarball, its checksum and a size report, so export it with
#   docker buildx bake amd64     (see docker-bake.hcl)
#
# Versions live in versions.env. ALPINE_VERSION must match it; the base stage
# checks that. GO_VERSION must match mise.toml; the launcher CI step checks that.
ARG ALPINE_VERSION=3.24
ARG GO_VERSION=1.27.1

# Sources are architecture independent, so fetch them once on the build host
# instead of under emulation.
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS sources
RUN apk add --no-cache curl
COPY versions.env /build/versions.env
COPY scripts/fetch-sources.sh /build/scripts/
RUN /build/scripts/fetch-sources.sh /build/versions.env /build/src

# Toolchain and the static libraries everything links against.
FROM alpine:${ALPINE_VERSION} AS base
RUN apk add --no-cache \
      build-base linux-headers pkgconf file perl tar xz \
      openssl-dev openssl-libs-static \
      zlib-dev zlib-static \
      expat-dev expat-static \
      pcre2-dev pcre2-static \
      nghttp2-dev nghttp2-static \
      ca-certificates-bundle
COPY versions.env /build/versions.env
RUN . /build/versions.env && case "$(cat /etc/alpine-release)" in \
      "$ALPINE_VERSION".*) ;; \
      *) echo "Dockerfile ALPINE_VERSION does not match versions.env ($ALPINE_VERSION)" >&2; exit 1 ;; \
    esac
WORKDIR /build

FROM base AS curl
COPY --from=sources /build/src/curl-* /build/src/
COPY scripts/build-curl.sh /build/scripts/
RUN /build/scripts/build-curl.sh /build/versions.env /build/src

FROM curl AS git
COPY --from=sources /build/src/git-* /build/src/
COPY scripts/build-git.sh /build/scripts/
RUN /build/scripts/build-git.sh /build/versions.env /build/src /stage/git

FROM base AS openssh
COPY --from=sources /build/src/openssh-* /build/src/
COPY scripts/build-openssh.sh /build/scripts/
RUN /build/scripts/build-openssh.sh /build/versions.env /build/src /stage/ssh

# Go cross-compiles, so the launcher builds natively on the build host. The
# unit tests run here too, so a broken launcher never reaches a bundle.
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS launcher
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY launcher/ ./
RUN test -z "$(gofmt -l .)" && go vet ./... && go test ./...
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go build -trimpath -ldflags='-s -w' -o /stage/launcher/git .

FROM base AS bundle
COPY --from=git /stage/git /stage/git
COPY --from=openssh /stage/ssh /stage/ssh
COPY --from=launcher /stage/launcher /stage/launcher
COPY scripts/package.sh /build/scripts/
RUN /build/scripts/package.sh /build/versions.env /stage/git /stage/ssh /stage/launcher/git /dist

FROM scratch AS dist
COPY --from=bundle /dist/ /
