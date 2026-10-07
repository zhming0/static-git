# Git server for scripts/matrix-test.sh: HTTPS with a private CA (optionally
# with basic auth), SSH, and an HTTP proxy. See entrypoint.sh.
ARG ALPINE_VERSION=3.24
ARG GO_VERSION=1.27.1

FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /githttpd .

FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache git git-daemon openssh-server openssh-keygen openssl tinyproxy
COPY --from=build /githttpd /usr/local/bin/githttpd
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENV AUTH_USER=agent AUTH_PASS=s3cret
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
