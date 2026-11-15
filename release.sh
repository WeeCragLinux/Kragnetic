#!/usr/bin/env bash
# release.sh — build, publish, sign and promote Kragnetic images in one step.
#
# For each variant (default, nvidia):
#   1. skip when the upstream base digest is unchanged (unless --force)
#   2. build with `dcli-bootc update --no-switch --no-import` (unless --no-build)
#   3. push the image to a dated tag (:YYYY-MM-DD)
#   4. sign that digest with cosign
#   5. verify the dated tag
#   6. promote the same digest to the mutable tag (:default / :nvidia)
#   7. verify the mutable tag
#
# Signatures are bound to the image digest, so the mutable tag only ever moves
# to an image that is already signed. If signing fails, users keep pulling the
# previous signed image.
#
# Usage:
#   ./release.sh                 # both variants, skip unchanged bases
#   ./release.sh nvidia          # one variant
#   ./release.sh --force         # rebuild even if the base is unchanged
#   ./release.sh --no-build      # push/sign the current local images
#
# Environment (overridable):
#   REPO             registry repository   (ghcr.io/weecraglinux/kragnetic)
#   LOCAL_IMAGE      local image name      (localhost/kragnetic)
#   ROOT_AUTHFILE    root skopeo authfile  (/root/.config/containers/auth.json)
#   COSIGN_KEY       private key           (~/cosign/cosign.key)
#   COSIGN_PUB       public key            (~/cosign/cosign.pub)
#   COSIGN_ENV       root-only env file    (/etc/kragnetic/release.env)
#   COSIGN_PASSWORD  key password          (otherwise read from COSIGN_ENV)
#   DATED_TAG        override dated tag    ($(date +%Y-%m-%d))
#   RELEASE_CACHE=1  let dcli-bootc reuse the podman layer cache

set -euo pipefail

REPO="${REPO:-ghcr.io/weecraglinux/kragnetic}"
LOCAL_IMAGE="${LOCAL_IMAGE:-localhost/kragnetic}"
ROOT_AUTHFILE="${ROOT_AUTHFILE:-/root/.config/containers/auth.json}"
COSIGN_KEY="${COSIGN_KEY:-$HOME/cosign/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-$HOME/cosign/cosign.pub}"
COSIGN_ENV="${COSIGN_ENV:-/etc/kragnetic/release.env}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kragnetic/release}"
DATED_TAG="${DATED_TAG:-$(date +%Y-%m-%d)}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

VARIANT="all"
FORCE=0
NO_BUILD=0

info() { printf '\n== %s\n' "$*"; }
die()  { printf 'release: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while (($#)); do
    case "$1" in
      default|nvidia|all) VARIANT="$1" ;;
      --force|-f)         FORCE=1 ;;
      --no-build)         NO_BUILD=1 ;;
      -h|--help)          usage ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

base_for() {
  case "$1" in
    default) printf '%s\n' "ghcr.io/ublue-os/bazzite:stable" ;;
    nvidia)  printf '%s\n' "ghcr.io/ublue-os/bazzite-nvidia-open:stable" ;;
  esac
}

tag_for() { printf '%s\n' "$1"; }

base_digest() {
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1"
}

state_file() { printf '%s/%s.base-digest\n' "$STATE_DIR" "$1"; }

load_cosign_password() {
  if [[ -n "${COSIGN_PASSWORD:-}" ]]; then
    export COSIGN_PASSWORD
    return
  fi
  [[ -f "$COSIGN_ENV" ]] || die "no COSIGN_PASSWORD and $COSIGN_ENV is missing"
  COSIGN_PASSWORD="$(sudo awk -F'=' '/^COSIGN_PASSWORD=/{sub(/^COSIGN_PASSWORD=/,""); print; exit}' "$COSIGN_ENV")"
  [[ -n "$COSIGN_PASSWORD" ]] || die "$COSIGN_ENV has no COSIGN_PASSWORD= line"
  export COSIGN_PASSWORD
}

preflight() {
  local missing=()
  for c in dcli-bootc skopeo cosign jq sudo; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"

  [[ -f "$PROJECT_DIR/.dcli-bootc" ]] || die "not a dcli-bootc project (no .dcli-bootc)"
  [[ -f "$COSIGN_KEY" ]] || die "signing key not found: $COSIGN_KEY"
  [[ -f "$COSIGN_PUB" ]] || die "public key not found: $COSIGN_PUB"

  sudo -v

  local login
  login="$(sudo skopeo login --authfile "$ROOT_AUTHFILE" --get-login ghcr.io 2>/dev/null || true)"
  [[ "$login" == "weecraglinux" ]] \
    || die "root skopeo is not logged in to ghcr.io as weecraglinux (got '${login:-none}')"

  if ! jq -e '.auths["ghcr.io"]' "$HOME/.docker/config.json" >/dev/null 2>&1; then
    printf 'release: warning: cosign is not logged in to ghcr.io (run: cosign login ghcr.io -u weecraglinux)\n' >&2
  fi

  mkdir -p "$STATE_DIR"
  load_cosign_password
}

release_variant() {
  local v="$1" base tag prev cur local_digest reg_digest

  base="$(base_for "$v")"
  tag="$(tag_for "$v")"
  cur="$(base_digest "$base")"
  prev="$(cat "$(state_file "$v")" 2>/dev/null || true)"

  info "$v: base $base"
  printf '   base digest: %s\n' "$cur"

  if ((NO_BUILD == 0 && FORCE == 0)) && [[ "$cur" == "$prev" ]]; then
    printf '   unchanged since last release — skipping (use --force to rebuild)\n'
    return 0
  fi

  if ((NO_BUILD == 0)); then
    local args=(update --no-switch --no-import)
    [[ "$v" == "nvidia" ]] && args+=(--nvidia)
    ((RELEASE_CACHE == 1)) && args+=(--cache)

    info "$v: building (dcli-bootc ${args[*]})"
    dcli-bootc "${args[@]}"
    sudo -v
  else
    info "$v: --no-build, using the existing local image"
  fi

  sudo podman image exists "$LOCAL_IMAGE:$tag" \
    || die "$LOCAL_IMAGE:$tag is missing — build it first"
  local_digest="$(sudo podman image inspect "$LOCAL_IMAGE:$tag" --format '{{.Digest}}')"

  info "$v: pushing $REPO:$DATED_TAG"
  sudo skopeo copy --authfile "$ROOT_AUTHFILE" --all \
    "containers-storage:$LOCAL_IMAGE:$tag" \
    "docker://$REPO:$DATED_TAG"

  reg_digest="$(sudo skopeo inspect --authfile "$ROOT_AUTHFILE" --format '{{.Digest}}' \
    "docker://$REPO:$DATED_TAG")"
  [[ "$reg_digest" == "$local_digest" ]] \
    || die "registry digest $reg_digest does not match local $local_digest"

  info "$v: signing $REPO@$reg_digest"
  cosign sign --key "$COSIGN_KEY" --yes "$REPO@$reg_digest"

  info "$v: verifying dated tag $REPO:$DATED_TAG"
  cosign verify --key "$COSIGN_PUB" "$REPO:$DATED_TAG" >/dev/null

  info "$v: promoting $DATED_TAG -> $tag"
  sudo skopeo copy --authfile "$ROOT_AUTHFILE" --all \
    "docker://$REPO:$DATED_TAG" \
    "docker://$REPO:$tag"

  info "$v: verifying promoted tag $REPO:$tag"
  cosign verify --key "$COSIGN_PUB" "$REPO:$tag" >/dev/null

  printf '%s\n' "$cur" > "$(state_file "$v")"
  printf '   released %s:%s at %s\n' "$REPO" "$tag" "$reg_digest"
}

main() {
  parse_args "$@"
  preflight

  local variants=()
  case "$VARIANT" in
    all) variants=(default nvidia) ;;
    *)   variants=("$VARIANT") ;;
  esac

  local v
  for v in "${variants[@]}"; do
    release_variant "$v"
  done

  info "done"
  for v in "${variants[@]}"; do
    printf '%s: %s:%s\n' "$v" "$REPO" "$(tag_for "$v")"
  done
}

main "$@"
