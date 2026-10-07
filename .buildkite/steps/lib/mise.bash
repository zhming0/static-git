# shellcheck shell=bash
# Shared toolchain bootstrap. Source this, then call ensure_tools before using
# any tool that mise.toml pins.
#
# mise.toml holds every tool version. Only mise itself is pinned here, because
# something has to exist before mise can read its own config.
MISE_VERSION="2026.8.16"
MISE_SHA256_x64="1445289f35e1a5a7216e1ffee5b34c5b9bd46793224e7e6c335503de9d9df0b2"
MISE_SHA256_arm64="21a03117d27028b1b4602bc83d9aefdccd55325ac3da45f7e28c9320627dcdc6"

install_mise() {
  local arch sha
  case "$(uname -m)" in
    x86_64)        arch="linux-x64-musl";   sha="$MISE_SHA256_x64" ;;
    aarch64|arm64) arch="linux-arm64-musl"; sha="$MISE_SHA256_arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
  esac

  echo "--- :toolbox: Installing mise ${MISE_VERSION}"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-${arch}.tar.gz" -o /tmp/mise.tar.gz
  echo "${sha}  /tmp/mise.tar.gz" | sha256sum -c -
  tar -xzf /tmp/mise.tar.gz -C "$HOME/.local/bin" --strip-components=2 mise/bin/mise
  rm /tmp/mise.tar.gz
  PATH="$HOME/.local/bin:$PATH"
}

# Put every tool that mise.toml pins on PATH.
ensure_tools() {
  command -v mise >/dev/null 2>&1 || install_mise

  local root
  root="$(git rev-parse --show-toplevel)"

  # The cache speeds up `mise install` across CI builds. It needs the job's
  # access token, which only exists in a real CI step.
  if [[ -n "${BUILDKITE_AGENT_ACCESS_TOKEN:-}" ]]; then
    echo "--- :recycle: Restoring the toolchain cache"
    buildkite-agent cache restore --name mise
  fi

  echo "--- :toolbox: Installing tools from mise.toml"
  mise trust "${root}/mise.toml"
  mise install --cd "$root"

  if [[ -n "${BUILDKITE_AGENT_ACCESS_TOKEN:-}" ]]; then
    buildkite-agent cache save --name mise
  fi
  eval "$(mise activate bash --shims)"
}
