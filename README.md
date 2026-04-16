# mayday-electronics-dot-com

NixOS flake + OpenTofu for the single VPS that runs
[maydayelectronics.com](https://maydayelectronics.com) (Ghost CMS on a Vultr
instance, DNS on Cloudflare, state/backups on Backblaze B2).

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake entry point: NixOS modules/configs, `colmenaHive`, apps, VM |
| `configuration.nix` | Site-specific wiring (domain, SOPS paths, Ghost settings) |
| `modules/ghost-cms/` | Reusable Ghost CMS module (OCI container + MySQL + restic) |
| `main.tf` | OpenTofu: Vultr VPS, Cloudflare DNS, B2 state backend |
| `disk-config.nix` / `hardware.nix` | disko + hardware for the real VPS |
| `apps/` | Helper scripts surfaced as `nix run .#<app>` |
| `secrets/` | sops-encrypted YAML (real + dev) and the committed dev age key |

## Local development — boot the whole stack in a VM

```
nix run .#vm
```

Builds a QEMU VM of the full mayday-vps config, forwards host `8080`→`80`
and `2222`→`22`, logs in with `root`/`root`. Ghost admin is at
<http://localhost:8080/ghost/>. Dev secrets are dummy values encrypted to
the committed dev age key at `secrets/dev-age-key.txt`.

### Editing dev secrets

```
nix run .#edit-dev-secrets
```

Opens `secrets/dev-secrets.yaml` in sops with the dev age key
pre-configured.

## Deployment

Colmena deploys the configured hive. The VPS age private key is uploaded
from `~/.config/sops/age/mayday-vps.txt` pre-activation, so sops-nix can
decrypt secrets on the same deploy that installs the key.

```
nix develop                # exports TF_VAR_* + puts colmena/sops on PATH
tofu apply                 # creates/updates the VPS + DNS
colmena apply              # deploys the NixOS config
```

To edit production secrets:

```
sops secrets/secrets.yaml
```

(requires the matching age private key on your workstation.)

## Ghost image pin

The module loads a pinned `ghost:6-alpine` OCI tarball — podman does
**not** pull at runtime. Refresh the pin:

```
nix run .#update-ghost-image          # latest 6-alpine
nix run .#update-ghost-image -- 6.28  # a specific tag
```

Rewrites `modules/ghost-cms/image.nix` with a fresh digest + SRI hash.

## `ghost-restic` — admin wrapper for the B2 backups

Installed in `environment.systemPackages` on the VPS. Pre-sets
`RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, and the B2 `AWS_*` creds
from the same sops-nix paths the backup service uses, then execs
`restic`. Run as root on the VPS:

```
ghost-restic snapshots                                  # list snapshots
ghost-restic check                                      # verify repo integrity
ghost-restic restore latest --target /tmp/restore       # restore to scratch dir
ghost-restic forget --keep-daily 7 --keep-weekly 4 --prune
```

Any `restic` subcommand works — the wrapper just handles auth/repo
wiring. The scheduled daily backup is
`services.restic.backups.ghost-cms` and fires via its systemd timer; its
`backupPrepareCommand` runs `mysql-backup.service` synchronously so each
snapshot contains a just-taken mysqldump plus `/var/lib/ghost-cms/content`.

### Restore drill

```
ghost-restic restore latest --target /tmp/restore
zcat /tmp/restore/var/backup/mysql/ghost.gz | head     # sanity-check SQL
# then import into a scratch MySQL and diff tables as desired
```

## Secret layout (`secrets/secrets.yaml`)

```yaml
vultr_api: …
cloudflare_api_token: …
b2:
  tf_state:
    access_key: …      # Tofu state backend
    secret_key: …
  backup:
    access_key: …      # restic → B2 for Ghost backups
    secret_key: …
ghost:
  db_password: …
  smtp_user: …
  smtp_password: …
restic:
  password: …          # restic repo password
```

Map of YAML paths → module secret names lives in
`configuration.nix::services.ghost-cms.sopsSecretPaths`.
