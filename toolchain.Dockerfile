# The CMake / protoc / pkg-config toolchain `make release` runs the library build, the test suite
# and the packaging dry-run in when the release host has no cmake (USE_DOCKER_TOOLCHAIN in the
# Makefile). Same base and the same packages as .github/workflows/ci.yml installs on its
# ubuntu-24.04 runner, so the release build matches CI: ubuntu-24.04 ships protobuf 3.21.12,
# the runtime the committed gencode in api/ requires. Pinned by digest so the toolchain cannot
# move under a release. openssl is the one addition: the TLS tests mint their PKI with it, and
# the GitHub runner image ships it preinstalled.
FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config \
        protobuf-compiler libprotobuf-dev \
        protobuf-compiler-grpc libgrpc++-dev libgrpc-dev libabsl-dev \
        libgtest-dev gcovr openssl \
    && rm -rf /var/lib/apt/lists/*
