# Building and publishing

There is **no CI** for this project by design. Images are built locally, pushed
to GHCR, and signed with a local cosign key.

| Variant | Tag | Published |
|---|---|---|
| default (AMD / Intel) | `:default` | yes |
| nvidia (NVIDIA open) | `:nvidia` | yes |
| nvidia-legacy | `:nvidia-legacy` | no (dormant) |

Images live at `ghcr.io/weecraglinux/kragnetic`. The `nvidia-legacy`
kickstart exists and points at that registry, but the tag is not built or
published, so its ISO will not install.

## One-click release (`release.sh`)

For the normal case — rebuild when Bazzite or KineticWE moves, push and sign —
use:

```bash
./release.sh                  # build, push and sign both variants
./release.sh nvidia           # just one variant
./release.sh --skip-unchanged # only rebuild when something actually changed
./release.sh --force          # with --skip-unchanged: build regardless
./release.sh --no-build       # publish the local images as they are
```

Per variant it runs:

1. `dcli-bootc update --no-switch --no-import`
2. push straight to the variant tag (`:default` / `:nvidia`), overwriting it
3. `cosign sign` **by digest**, in the legacy `.sig` format bootc verifies
4. `cosign verify` the tag

Every run rebuilds by default, which is what picks up KineticWE changes: those
packages come from the `theblackdon/kwee` COPR at build time and the Bazzite
base digest does not move when they are updated.

With `--skip-unchanged`, a fingerprint is compared against
`~/.local/state/kragnetic/release/<variant>.fingerprint` before building:

- upstream base digest (`bazzite:stable` / `bazzite-nvidia-open:stable`)
- latest **successful** build in the KineticWE COPR (read from the COPR API)
- git `HEAD` plus a hash of the working-tree status

If any of those changed, it builds. If the COPR API can't be queried, the
script treats the state as changed so an update is never missed.

Each release replaces the tag in place. The script pushes and signs back to
back; until the signature lands, an install pulling that tag will refuse it, so
avoid doing the steps by hand with a long gap between them.

### Key password for unattended runs

`release.sh` reads the cosign key password from a root-only env file:

```bash
sudo install -d -m 700 /etc/kragnetic
printf 'COSIGN_PASSWORD=%s\n' '<your-cosign-key-password>' \
  | sudo tee /etc/kragnetic/release.env >/dev/null
sudo chmod 600 /etc/kragnetic/release.env
```

Alternatively export `COSIGN_PASSWORD` in the environment when invoking the
script. The script reads the env file with `sudo`, so `/etc/kragnetic` can stay
mode `700` (root-only); the file itself must be `600`. The script preflights the
toolchain, keypair, and root's GHCR login, and aborts before changing anything
if a check fails. It warns if the env file is not mode 600.

Useful overrides: `REPO`, `LOCAL_IMAGE`, `ROOT_AUTHFILE`, `COSIGN_KEY`,
`COSIGN_PUB`, `COSIGN_ENV`, `KINETICWE_COPR`, and `RELEASE_CACHE=1` to reuse
the podman layer cache (avoid it when you want fresh COPR packages).

## 1. One-time setup

### Build tools

`dcli-bootc` is baked into the image. On a plain Bazzite build host:

```bash
sudo curl -Lo /etc/yum.repos.d/theblackdon-dcli-bootc.repo \
  https://copr.fedorainfracloud.org/coprs/theblackdon/dcli-bootc/repo/fedora-$(rpm -E %fedora)/theblackdon-dcli-bootc-fedora-$(rpm -E %fedora).repo
sudo rpm-ostree install dcli-bootc podman skopeo cosign
sudo systemctl reboot
```

### Signing keypair

Generate the keypair **outside the repo** and back it up:

```bash
mkdir -p ~/cosign && cd ~/cosign
cosign generate-key-pair        # cosign.key (private) + cosign.pub (public)
```

- `cosign.pub` is committed to the image at
  `files/etc/pki/containers/weecraglinux.pub`.
- `cosign.key` must never be committed. `.gitignore` covers it.
- Losing `cosign.key` means existing installs cannot verify new images until
  the policy in the image is updated with a new public key.

### Registry credentials

Create a GitHub PAT with **`write:packages`** (classic) or **Packages: Read and
write** (fine-grained), then:

```bash
sudo skopeo login ghcr.io -u weecraglinux   # rootful, for skopeo copy
cosign login ghcr.io -u weecraglinux        # user, for signing
```

After the first push, set both packages **public** (GitHub → your profile →
Packages → package → Settings → Change visibility). New installs cannot pull a
private package without credentials.

## 2. Build

```bash
dcli-bootc build              # → localhost/kragnetic:default
dcli-bootc build --nvidia     # → localhost/kragnetic:nvidia
```

Each build must happen after any change to `modules/` or `files/`, since the
signing policy, public key, and branding are baked into the image.

## 3. Push to GHCR

```bash
sudo skopeo copy --all containers-storage:localhost/kragnetic:default \
  docker://ghcr.io/weecraglinux/kragnetic:default
sudo skopeo copy --all containers-storage:localhost/kragnetic:nvidia \
  docker://ghcr.io/weecraglinux/kragnetic:nvidia
```

Verify the push landed:

```bash
skopeo list-tags docker://ghcr.io/weecraglinux/kragnetic
skopeo inspect docker://ghcr.io/weecraglinux/kragnetic:default | jq '{Digest,Labels}'
```

## 4. Sign and verify

**Sign after every push.** A signature is bound to the image digest, so
rebuilding and re-pushing a tag invalidates the previous signature.

cosign v3 defaults to the Sigstore bundle format attached through the OCI
referrers API. containers/image — and therefore bootc, podman and skopeo — only
reads the legacy `sha256-<digest>.sig` tag, so v3 needs the deprecated flags
below. `release.sh` adds them automatically.

```bash
cosign sign --key ~/cosign/cosign.key --yes \
  --tlog-upload=false --new-bundle-format=false --use-signing-config=false \
  ghcr.io/weecraglinux/kragnetic:default
cosign sign --key ~/cosign/cosign.key --yes \
  --tlog-upload=false --new-bundle-format=false --use-signing-config=false \
  ghcr.io/weecraglinux/kragnetic:nvidia

cosign verify --key ~/cosign/cosign.pub ghcr.io/weecraglinux/kragnetic:default
cosign verify --key ~/cosign/cosign.pub ghcr.io/weecraglinux/kragnetic:nvidia
```

Confirm the legacy attachment exists — bootc cannot verify without it:

```bash
skopeo list-tags docker://ghcr.io/weecraglinux/kragnetic | grep '\.sig'
```

### How verification is enforced

Three pieces are baked into the image:

1. `files/etc/pki/containers/weecraglinux.pub` — the public key.
2. `files/etc/containers/registries.d/weecraglinux.yaml` — tells pullers to
   fetch the `.sig` attachment from GHCR.
3. `modules/signing.yaml` — merges a `sigstoreSigned` entry for
   `ghcr.io/weecraglinux` into `/etc/containers/policy.json`, preserving
   Bazzite's existing `ghcr.io/ublue-os` policy.

The installer kickstarts additionally pass `--enforce-container-sigpolicy` to
`bootc switch`, so an ISO refuses an unsigned image at install time.

If an installer build fails at the `%post` switch, remove only the
`--enforce-container-sigpolicy` flag from the kickstart: the policy entry still
verifies every pull.

## 5. Build installer ISOs

Only after the matching image tag is pushed **and signed**:

```bash
./build-iso.sh           # → output/kragnetic-<date>.iso
./build-iso.sh nvidia    # → output/kragnetic-nvidia-<date>.iso
```

`build-iso.sh` pulls `ghcr.io/weecraglinux/kragnetic:<tag>` into rootful podman
storage. Set `LOCAL=1` to use a locally built image instead.

## 6. Test an install

On a VM:

```bash
bootc status          # origin should be ostree-image-signed:docker://ghcr.io/weecraglinux/kragnetic:default
sudo bootc upgrade --check
```

An unsigned tag in the same namespace should be refused at pull time.

## 7. Rebuilding later

1. `dcli-bootc update` (or `build`)
2. `skopeo copy` the new image
3. **`cosign sign` again**
4. Rebuild ISOs only if you ship them

## Publishing ISOs to Cloudflare R2

ISOs are too large for Cloudflare Pages (25 MiB/file) and `wrangler` (300 MiB
per object), so they live in an R2 bucket served from a custom domain with zero
egress fees.

### One-time setup

1. **Create the bucket**: Cloudflare dashboard → R2 → *Create bucket* →
   `kragnetic-isos`.
2. **Attach a domain**: bucket → *Settings* → *Custom Domains* →
   `dl.theblackdon.dev`.
3. **Create an API token**: R2 → *API* → *Manage API Tokens* → **Object Read &
   Write**, scoped to the bucket. Note the Access Key ID and Secret.
4. **Install rclone** (no root needed):

   ```bash
   curl -LO https://downloads.rclone.org/rclone-current-linux-amd64.zip
   unzip -o rclone-current-linux-amd64.zip
   install -m755 rclone-*/rclone ~/.local/bin/rclone
   ```

5. **Configure rclone** (`<ACCOUNT_ID>` is under R2 → *Account Details*):

   ```bash
   rclone config create r2 s3 \
     provider=Cloudflare \
     access_key_id='<ACCESS_KEY_ID>' \
     secret_access_key='<SECRET_ACCESS_KEY>' \
     endpoint='https://<ACCOUNT_ID>.r2.cloudflarestorage.com' \
     acl=private
   ```

### Upload

Use stable object names so links never change:

```bash
cd output
rclone copyto kragnetic-<date>.iso \
  r2:kragnetic-isos/kragnetic.iso \
  --s3-no-check-bucket --s3-upload-cutoff 256M --s3-chunk-size 256M --progress
rclone copyto kragnetic-nvidia-<date>.iso \
  r2:kragnetic-isos/kragnetic-nvidia.iso \
  --s3-no-check-bucket --s3-upload-cutoff 256M --s3-chunk-size 256M --progress
```

`--s3-no-check-bucket` is required: the scoped token cannot `CreateBucket`,
which rclone otherwise tries as a pre-flight check.

Served at:

```
https://dl.theblackdon.dev/kragnetic.iso
https://dl.theblackdon.dev/kragnetic-nvidia.iso
```

### Verify and update checksums

```bash
rclone lsjson --hash r2:kragnetic-isos
sha256sum output/kragnetic-<date>.iso
```

Update the matching SHA256 on the website after each upload.
