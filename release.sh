#!/usr/bin/env bash
# release.sh — build, publish and sign Kragnetic images in one step.
#
# For each variant (default, nvidia):
#   1. build with `dcli-bootc update --no-switch --no-import` (unless --no-build)
#   2. push straight to the variant tag (:default / :nvidia)
#   3. sign that digest with cosign
#   4. verify the tag
#
# By default every run rebuilds and publishes. With --skip-unchanged the script
# compares a fingerprint against the last successful release and skips when
# nothing changed. The fingerprint covers the upstream base digest, the latest
# successful KineticWE COPR build, and the local git working tree, so a Kinetic
# update alone is enough to trigger a rebuild.
#
# Each release overwrites the tag. Sign immediately after pushing: until the
# signature lands, an install pulling that tag will refuse it.
#
# Usage:
#   ./release.sh                 # build, push and sign both variants
#   ./release.sh nvidia          # one variant
#   ./release.sh --skip-unchanged  # only build when base/KineticWE/repo changed
#   ./release.sh --force         # with --skip-unchanged: build regardless
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
#   KINETICWE_COPR   COPR owner/project    (theblackdon/kwee)
#   RELEASE_CACHE=1  let dcli-bootc reuse the podman layer cache

set -euo pipefail

REPO="${REPO:-ghcr.io/weecraglinux/kragnetic}"
LOCAL_IMAGE="${LOCAL_IMAGE:-localhost/kragnetic}"
ROOT_AUTHFILE="${ROOT_AUTHFILE:-/root/.config/containers/auth.json}"
COSIGN_KEY="${COSIGN_KEY:-$HOME/cosign/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-$HOME/cosign/cosign.pub}"
COSIGN_ENV="${COSIGN_ENV:-/etc/kragnetic/release.env}"
KINETICWE_COPR="${KINETICWE_COPR:-theblackdon/kwee}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kragnetic/release}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

VARIANT="all"
FORCE=0
NO_BUILD=0
SKIP_UNCHANGED=0

info() { printf '\n== %s\n' "$*"; }
die()  { printf 'release: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
  exit 0
}

parse_args() {
  while (($#)); do
    case "$1" in
      default|nvidia|all)  VARIANT="$1" ;;
      --force|-f)          FORCE=1 ;;
      --no-build)          NO_BUILD=1 ;;
      --skip-unchanged)    SKIP_UNCHANGED=1 ;;
      -h|--help)           usage ;;
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

state_file() { printf '%s/%s.fingerprint\n' "$STATE_DIR" "$1"; }

# cosign v3+ writes the new Sigstore bundle format attached via OCI referrers.
# The deprecated flags below force the legacy sha256-<digest>.sig attachment
# that containers/image (bootc/podman/skopeo) can actually verify.
cosign_needs_legacy_flags() {
  local major
  major="$(cosign version 2>/dev/null \
    | awk -F': *' '/GitVersion/{print $2}' \
    | sed 's/^v//' | cut -d. -f1)"
  [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 3))
}

# Latest successful build in the KineticWE COPR, as "<build-id>-<version>".
# Empty output means the API could not be queried; callers treat that as
# "changed" so a network failure never hides an update.
kineticwe_fingerprint() {
  local owner="${KINETICWE_COPR%%/*}" project="${KINETICWE_COPR#*/}" json
  json="$(curl -fsSL --max-time 20 \
    "https://copr.fedorainfracloud.org/api_3/build/list?ownername=${owner}&projectname=${project}&limit=50" \
    2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  printf '%s' "$json" | jq -r '
    [.items[] | select(.state == "succeeded")][0]
    | if . == null then empty
      else "\(.id)-\(.source_package.version)" end
  ' 2>/dev/null || true
}

# Commit hash plus a hash of the working-tree status, so edits to modules/ or
# files/ also count as a change.
git_fingerprint() {
  if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local head dirty
    head="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    dirty="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf '%s-%s' "$head" "$dirty"
  else
    printf 'nogit'
  fi
}

fingerprint_for() {
  local base="$1" kin
  kin="$(kineticwe_fingerprint)"
  printf '%s|%s|%s\n' "$(base_digest "$base")" "${kin:-unknown}" "$(git_fingerprint)"
}

load_cosign_password() {
  if [[ -n "${COSIGN_PASSWORD:-}" ]]; then
    export COSIGN_PASSWORD
    return
  fi
  sudo test -f "$COSIGN_ENV" || die "no COSIGN_PASSWORD and $COSIGN_ENV is missing"
  COSIGN_PASSWORD="$(sudo awk -F'=' '/^COSIGN_PASSWORD=/{sub(/^COSIGN_PASSWORD=/,""); print; exit}' "$COSIGN_ENV")"
  [[ -n "$COSIGN_PASSWORD" ]] || die "$COSIGN_ENV has no COSIGN_PASSWORD= line"
  export COSIGN_PASSWORD
  trap 'unset COSIGN_PASSWORD' EXIT
}

preflight() {
  local missing=()
  for c in dcli-bootc skopeo cosign jq curl sudo; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"

  [[ -f "$PROJECT_DIR/.dcli-bootc" ]] || die "not a dcli-bootc project (no .dcli-bootc)"
  [[ -f "$COSIGN_KEY" ]] || die "signing key not found: $COSIGN_KEY"
  [[ -f "$COSIGN_PUB" ]] || die "public key not found: $COSIGN_PUB"

  sudo -v

  if sudo test -f "$COSIGN_ENV"; then
    local mode
    mode="$(sudo stat -c '%a' "$COSIGN_ENV" 2>/dev/null || echo unknown)"
    [[ "$mode" == "600" ]] \
      || printf 'release: warning: %s is mode %s, expected 600\n' "$COSIGN_ENV" "$mode" >&2
  fi

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
  local v="$1" base tag cur kin fp prev local_id reg_config reg_digest

  base="$(base_for "$v")"
  tag="$(tag_for "$v")"
  cur="$(base_digest "$base")"

  info "$v: base $base"
  printf '   base digest: %s\n' "$cur"

  if ((NO_BUILD == 0 && SKIP_UNCHANGED == 1 && FORCE == 0)); then
    kin="$(kineticwe_fingerprint)"
    fp="${cur}|${kin:-unknown}|$(git_fingerprint)"
    prev="$(cat "$(state_file "$v")" 2>/dev/null || true)"
    printf '   kineticwe:   %s\n' "${kin:-unknown}"

    if [[ -n "$kin" && "$fp" == "$prev" ]]; then
      printf '   nothing changed since the last release — skipping (use --force)\n'
      return 0
    fi
  fi

  if ((NO_BUILD == 0)); then
    local args=(update --no-switch --no-import)
    [[ "$v" == "nvidia" ]] && args+=(--nvidia)
    (( ${RELEASE_CACHE:-0} == 1 )) && args+=(--cache)

    info "$v: building (dcli-bootc ${args[*]})"
    dcli-bootc "${args[@]}"
    sudo -v
  else
    info "$v: --no-build, using the existing local image"
  fi

  sudo podman image exists "$LOCAL_IMAGE:$tag" \
    || die "$LOCAL_IMAGE:$tag is missing — build it first"
  local_id="sha256:$(sudo podman image inspect "$LOCAL_IMAGE:$tag" --format '{{.Id}}' | sed 's/^sha256://')"
  printf '   image id:    %s\n' "$local_id"

  info "$v: pushing $REPO:$tag"
  sudo skopeo copy --authfile "$ROOT_AUTHFILE" --all \
    "containers-storage:$LOCAL_IMAGE:$tag" \
    "docker://$REPO:$tag"

  reg_digest="$(sudo skopeo inspect --authfile "$ROOT_AUTHFILE" --format '{{.Digest}}' \
    "docker://$REPO:$tag")"

  # Compare image-config digests, not manifest digests: containers-storage
  # layers are recompressed on push, so the manifest digest legitimately
  # changes while the image config (and therefore the image ID) does not.
  reg_config="$(sudo skopeo inspect --raw --authfile "$ROOT_AUTHFILE" \
    "docker://$REPO:$tag" | jq -r '.config.digest // empty')"
  if [[ -z "$reg_config" ]]; then
    local child
    child="$(sudo skopeo inspect --raw --authfile "$ROOT_AUTHFILE" \
      "docker://$REPO:$tag" \
      | jq -r '[.manifests[]? | select(.platform.os == "linux")][0].digest // empty')"
    if [[ -n "$child" ]]; then
      reg_config="$(sudo skopeo inspect --raw --authfile "$ROOT_AUTHFILE" \
        "docker://$REPO@$child" | jq -r '.config.digest // empty')"
    fi
  fi
  if [[ -n "$reg_config" ]]; then
    reg_config="sha256:${reg_config#sha256:}"
    [[ "$reg_config" == "$local_id" ]] \
      || die "registry config $reg_config does not match local image id $local_id"
  else
    printf '   warning: could not compare config digests\n' >&2
  fi

  info "$v: signing $REPO@$reg_digest"
  local sign_args=(sign --key "$COSIGN_KEY" --yes)
  if cosign_needs_legacy_flags; then
    # cosign v3 defaults to the Sigstore bundle format attached via OCI
    # referrers. containers/image (bootc, podman, skopeo) only reads the legacy
    # sha256-<digest>.sig tag, so force the old format.
    sign_args+=(--tlog-upload=false --new-bundle-format=false --use-signing-config=false)
  fi
  cosign "${sign_args[@]}" "$REPO@$reg_digest"

  # Fail loudly if the legacy attachment did not land: a tag pointing at an
  # image bootc cannot verify is worse than no release.
  local sig_tag="sha256-${reg_digest#sha256:}.sig"
  sudo skopeo list-tags --authfile "$ROOT_AUTHFILE" "docker://$REPO" \
    | jq -e --arg t "$sig_tag" '.Tags | index($t)' >/dev/null \
    || die "legacy signature tag $sig_tag is missing after signing"

  info "$v: verifying $REPO:$tag"
  cosign verify --key "$COSIGN_PUB" "$REPO:$tag" >/dev/null

  fingerprint_for "$base" > "$(state_file "$v")"
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
