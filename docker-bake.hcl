# One bundle per platform. Each target exports the tarball, its checksum and a
# size report into dist/<os>_<arch>/.
#
#   docker buildx bake            # native platform only
#   docker buildx bake all        # linux/amd64 and linux/arm64
#
# A non-native platform runs under QEMU, so it needs binfmt handlers:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64

group "default" {
  targets = ["native"]
}

group "all" {
  targets = ["amd64", "arm64"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "dist"
}

target "native" {
  inherits = ["_common"]
  output   = ["type=local,dest=dist/native"]
}

target "amd64" {
  inherits  = ["_common"]
  platforms = ["linux/amd64"]
  output    = ["type=local,dest=dist/linux_amd64"]
}

target "arm64" {
  inherits  = ["_common"]
  platforms = ["linux/arm64"]
  output    = ["type=local,dest=dist/linux_arm64"]
}
