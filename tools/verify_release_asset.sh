#!/bin/sh
# Proves that the GitHub release of a version is what consumers will get:
#   1. the release exists and its body (the RELEASE.md notes) is not empty,
#   2. the release archive <library>-<version>-<platform>.tar.gz AND its .sha256 are attached -
#      polled, because .github/workflows/release.yml (the ONLY uploader) attaches them a few
#      minutes after the tag push; a failed release run for the tag ends the wait at once,
#   3. both download, and `sha256sum -c` accepts the archive against the checksum next to it.
#
# Used in two places, so that the local release and CI check exactly the same thing:
#   - `make release_verify` pipes it into the pinned gh image (GH_IMAGE) - the release host needs
#     no gh and no sha256sum of its own;
#   - the last step of .github/workflows/release.yml runs it right after the upload.
#
# Usage: verify_release_asset.sh <version> <owner/repo> <library name>
# Needs gh, sha256sum and GH_TOKEN in the environment. Read-only: it changes nothing on GitHub.
# VERIFY_ATTEMPTS x VERIFY_INTERVAL_S (default 40 x 30 s = 20 min) bounds the wait for the assets.
set -eu

version="${1:?usage: verify_release_asset.sh <version> <owner/repo> <library name>}"
repo="${2:?usage: verify_release_asset.sh <version> <owner/repo> <library name>}"
library="${3:?usage: verify_release_asset.sh <version> <owner/repo> <library name>}"
attempts="${VERIFY_ATTEMPTS:-40}"
interval="${VERIFY_INTERVAL_S:-30}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# 1. The release and its notes. `gh release create -n ""` would have published an empty body.
body="$(gh release view "${version}" --repo "${repo}" --json body --jq .body)" \
  || fail "cannot read the GitHub release ${version} of ${repo} (see the gh error above)"
printf '%s' "${body}" | grep -q '[^[:space:]]' || fail "the GitHub release ${version} has an empty body"
echo "release ${version} exists and carries release notes"

# 2. Wait for both assets. The archive name carries the platform, so it is matched by prefix.
archive=""
attempt=1
while :; do
  names="$(gh release view "${version}" --repo "${repo}" --json assets --jq '.assets[].name')" \
    || fail "cannot list the assets of release ${version} (see the gh error above)"
  archive=""
  for name in ${names}; do
    case "${name}" in
      "${library}-${version}-"*.tar.gz) archive="${name}" ;;
    esac
  done
  if [ -n "${archive}" ] && printf '%s\n' "${names}" | grep -Fxq "${archive}.sha256"; then
    break
  fi
  # A release run for the tag that already FAILED will never upload - say so instead of waiting.
  conclusion="$(gh run list --repo "${repo}" --workflow release.yml --branch "${version}" --limit 1 \
    --json conclusion --jq '.[0].conclusion // ""' 2>/dev/null || true)"
  case "${conclusion}" in
    failure | cancelled | timed_out | startup_failure)
      fail "the release workflow run for tag ${version} ended '${conclusion}' - it attaches the archive, so nothing will be uploaded; see https://github.com/${repo}/actions/workflows/release.yml"
      ;;
  esac
  [ "${attempt}" -lt "${attempts}" ] \
    || fail "release ${version} still lacks ${library}-${version}-<platform>.tar.gz and its .sha256 after ${attempts} attempts; see https://github.com/${repo}/actions/workflows/release.yml"
  echo "attempt ${attempt}/${attempts}: the release archive is not attached yet, retrying in ${interval}s"
  attempt=$((attempt + 1))
  sleep "${interval}"
done
echo "attached: ${archive} + ${archive}.sha256"

# 3. Download what a consumer downloads and check it against the published checksum.
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT INT TERM
gh release download "${version}" --repo "${repo}" --pattern "${archive}" --pattern "${archive}.sha256" --dir "${workdir}" \
  || fail "cannot download the assets of release ${version} (see the gh error above)"
(cd "${workdir}" && sha256sum -c "${archive}.sha256") \
  || fail "${archive} does not match the published ${archive}.sha256"
echo "release ${version} verified: notes present, ${archive} downloads and matches its sha256"
