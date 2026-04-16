set -euo pipefail

tag="${1:-6-alpine}"
target="modules/ghost-cms/image.nix"

if [[ ! -f flake.nix ]]; then
  echo "error: run from the flake root (expected ./flake.nix)" >&2
  exit 1
fi

echo "Resolving ghost:${tag} ..."
output=$(nix-prefetch-docker --image-name ghost --image-tag "${tag}" --os linux --arch amd64 --quiet)

digest=$(printf '%s' "${output}" | awk -F'"' '/imageDigest/ { print $2 }')
hash=$(printf '%s' "${output}" | awk -F'"' '/^  hash/ { print $2 }')

if [[ -z "${digest}" || -z "${hash}" ]]; then
  echo "error: failed to parse nix-prefetch-docker output:" >&2
  echo "${output}" >&2
  exit 1
fi

cat > "${target}" <<EOF
{ dockerTools }:

dockerTools.pullImage {
  imageName = "ghost";
  imageDigest = "${digest}";
  hash = "${hash}";
  finalImageName = "ghost";
  finalImageTag = "${tag}";
}
EOF

echo "Updated ${target}:"
echo "  imageDigest = ${digest}"
echo "  hash        = ${hash}"
echo "  finalImageTag = ${tag}"
