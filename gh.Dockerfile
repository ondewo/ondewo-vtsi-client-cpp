# The GitHub CLI every release step that talks to GitHub runs in (GH_IMAGE in the Makefile): the
# token check of `make release_preflight`, the GitHub release of `make build_gh_release` and the
# asset check of `make release_verify`. The release host therefore needs no gh of its own - only
# docker, make, git and perl - and every release uses the same, pinned gh.
#
# Same digest-pinned base as toolchain.Dockerfile. gh is the upstream release tarball, pinned by
# version AND by its sha256 from gh_<version>_checksums.txt, so the image cannot change under a
# release. The Makefile tags the image with GH_VERSION, read from the ARG below - bump the version
# and both checksums together.
#
# Built with `docker build - < gh.Dockerfile`: there is no build context, so nothing of the
# working tree - least of all a devops-accounts clone - can end up in a layer. The token reaches
# the container per call as GH_TOKEN (`docker run -e GH_TOKEN`), never on an argv and never in a
# file: there is no `gh auth login` anywhere.
FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

ARG GH_VERSION=2.101.0
ARG GH_SHA256_AMD64=9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8
ARG GH_SHA256_ARM64=b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f

# ca-certificates stays: gh talks TLS to api.github.com. curl is only needed for the download.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         amd64) sum="${GH_SHA256_AMD64}" ;; \
         arm64) sum="${GH_SHA256_ARM64}" ;; \
         *) echo "no pinned gh checksum for ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/gh.tar.gz \
         "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
    && echo "${sum}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /tmp/gh* /var/lib/apt/lists/*

# No update check, no prompt, no spinner: every call is non-interactive and its output is a log.
ENV GH_NO_UPDATE_NOTIFIER=1 \
    GH_PROMPT_DISABLED=1 \
    GH_SPINNER_DISABLED=1
