#!/usr/bin/env bash
# check-updates.sh — are the published Kragnetic images behind their inputs?
#
# Read-only: needs skopeo, jq, curl. No podman, no sudo, no signing key.
#
# Per variant:
#   bazzite — rpmostree.inputhash from ghcr.io/ublue-os/bazzite*:stable vs the
#             hash inherited by the published image (Bazzite's OCI labels are
#             carried through every Kragnetic layer, so this needs no pull)
#   kwee    — newest successful COPR build time vs the image's build time
#
# Exit: 0 = current, 10 = rebuild/publish needed, 2 = could not check.
#
# Usage:
#   ./check-updates.sh                 # both variants
#   ./check-updates.sh nvidia          # one variant
#   VARIANTS=nvidia ./check-updates.sh # same, via environment
set -euo pipefail

REPO="${REPO:-ghcr.io/weecraglinux/kragnetic}"
KWEE_COPR="${KWEE_COPR:-theblackdon/kwee}"
VARIANTS="${1:-${VARIANTS:-default nvidia}}"

die() { printf 'check-updates: %s\n' "$*" >&2; exit 2; }

for c in skopeo jq curl date; do
  command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
done

base_for() {
  case "$1" in
    default) printf '%s\n' "ghcr.io/ublue-os/bazzite:stable" ;;
    nvidia)  printf '%s\n' "ghcr.io/ublue-os/bazzite-nvidia-open:stable" ;;
    *)       return 1 ;;
  esac
}

inspect() { skopeo inspect --no-tags "docker://${1#docker://}" 2>/dev/null; }

# KineticWE: newest successful COPR build
kwee_id=? kwee_ver=unknown kwee_epoch=0
owner="${KWEE_COPR%%/*}"
project="${KWEE_COPR#*/}"
if kwee_json="$(curl -fsSL --max-time 20 \
     "https://copr.fedorainfracloud.org/api_3/build/list?ownername=${owner}&projectname=${project}&limit=50")"; then
  line="$(printf '%s' "$kwee_json" | jq -r '
    [ .items[] | select(.state == "succeeded") ]
    | max_by(.ended_on // 0)
    | "\(.id)\t\(.source_package.version)\t\(.ended_on // 0)"' 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    IFS=$'\t' read -r kwee_id kwee_ver kwee_epoch <<<"$line"
  fi
else
  echo "warning: COPR query failed; KineticWE state unknown" >&2
fi

need=0
failed=0

for v in $VARIANTS; do
  if ! base="$(base_for "$v")"; then
    printf '== %s: unknown variant\n' "$v"
    failed=1
    continue
  fi
  printf '\n== %s  (%s)\n' "$v" "$REPO:$v"
  printf '   base ref: %s\n' "$base"

  if ! bj="$(inspect "$base")"; then
    printf '   ERROR: cannot inspect %s\n' "$base"
    failed=1
    continue
  fi
  if ! ij="$(inspect "$REPO:$v")"; then
    printf '   no published image — release needed\n'
    need=1
    continue
  fi

  b_ver="$(jq -r '.Labels["org.opencontainers.image.version"] // "?"' <<<"$bj")"
  b_hash="$(jq -r '.Labels["rpmostree.inputhash"] // ""' <<<"$bj")"
  i_ver="$(jq -r '.Labels["org.opencontainers.image.version"] // "?"' <<<"$ij")"
  i_hash="$(jq -r '.Labels["rpmostree.inputhash"] // ""' <<<"$ij")"
  i_created="$(jq -r '.Created // ""' <<<"$ij")"

  base_changed=0
  if [[ -n "$b_hash" && -n "$i_hash" ]]; then
    [[ "$b_hash" == "$i_hash" ]] || base_changed=1
  else
    [[ "$b_ver" == "$i_ver" ]] || base_changed=1
  fi

  kwee_changed=0
  created_epoch="$(date -d "$i_created" +%s 2>/dev/null || echo 0)"
  if (( kwee_epoch > 0 && created_epoch > 0 && kwee_epoch > created_epoch )); then
    kwee_changed=1
  fi

  printf '   bazzite : %s\n' "$b_ver"
  printf '   image   : %s  built %s\n' "$i_ver" "${i_created:-unknown}"
  printf '   kwee    : %s (build %s)\n' "$kwee_ver" "$kwee_id"

  if (( base_changed )); then
    printf '   base    : CHANGED\n'
  elif [[ "$b_ver" != "$i_ver" ]]; then
    printf '   base    : unchanged (same content hash; label %s -> %s)\n' "$i_ver" "$b_ver"
  else
    printf '   base    : unchanged\n'
  fi

  if (( kwee_changed )); then
    printf '   kwee    : CHANGED (newer COPR build than the image)\n'
  else
    printf '   kwee    : unchanged\n'
  fi

  if (( base_changed || kwee_changed )); then
    printf '   => rebuild + publish\n'
    need=1
  else
    printf '   => up to date\n'
  fi
done

printf '\n'
if (( failed )); then
  printf 'one or more checks could not run\n' >&2
  exit 2
fi
if (( need )); then
  printf 'update available\n'
  exit 10
fi
printf 'everything is current\n'
