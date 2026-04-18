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
| `mailserver.nix` | simple-nixos-mailserver setup (Postfix + Dovecot + Rspamd DKIM) |
| `main.tf` | OpenTofu: Vultr VPS, Cloudflare DNS + mail records, reverse DNS, B2 state backend |
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

## Mail

`mailserver.nix` runs [simple-nixos-mailserver](https://gitlab.com/simple-nixos-mailserver/nixos-mailserver)
alongside Ghost: Postfix + Dovecot + Rspamd (DKIM sign/verify), ACME cert
shared with nginx via `certificateScheme = "acme-nginx"`.

**Mailboxes** (4 real, rest are aliases):

| Address | Type |
| --- | --- |
| `larry@maydayelectronics.com` | real; also receives `postmaster@`, `abuse@`, `hostmaster@`, and the shared aliases below |
| `dan@maydayelectronics.com` | real; also receives the shared aliases below |
| `ghost@maydayelectronics.com` | real; used by Ghost to auth against local Postfix for transactional mail |
| `catchall@maydayelectronics.com` | real; `catchAll` for anything not matched above |
| `support@`, `sales@`, `hello@` | aliases → fan out to **both** `larry@` and `dan@` |

**Client config** for larry/dan/ghost mailboxes:

| | Incoming (IMAP) | Outgoing (SMTP) |
| --- | --- | --- |
| Host | `mx.maydayelectronics.com` | `mx.maydayelectronics.com` |
| Port | `993` | `465` (preferred) or `587` |
| Security | SSL/TLS | SSL/TLS (465) or STARTTLS (587) |
| Auth | Normal password | Normal password |
| Username | full email address | full email address |

### Setting / updating a mailbox password

```bash
nix run .#mail-admin -- set-password larry     # or dan | ghost | catchall
```

Prompts for a new password, bcrypts it, and writes it to
`secrets/secrets.yaml` at `mail.<mailbox>.hashedPassword` via
`sops set --value-stdin`. For the `ghost` mailbox it also updates
`ghost.smtp_user` and `ghost.smtp_password` (plaintext) so the Ghost
container can auth against Postfix.

Deploy the new hash with `colmena apply mayday-vps`. This only changes
the IMAP login password — the mailbox's at-rest encryption key is
wrapped by a separate per-mailbox `cryptPassword` and is untouched.

### Encryption at rest (Dovecot mail_crypt)

Dovecot's `mail_crypt` plugin encrypts each message on delivery using the
recipient mailbox's public key. Reading mail (IMAP FETCH) unwraps the
private key using a per-mailbox password stored in sops at
`mail.<mbx>.cryptPassword`. sops-nix renders a passwd-file-format
template at `/run/secrets/rendered/mail-userdb-extras` that dovecot
stacks ahead of simple-nixos-mailserver's userdb and merges
`mail_crypt_private_password` into each user lookup. Mail already on
disk from before the plugin was enabled stays plaintext; only new
deliveries are encrypted.

Decoupling `cryptPassword` from the IMAP password means rotating the
IMAP password never touches on-disk keys — no re-wrap, no risk of
drifting the two apart. The tradeoff is that anyone with access to
`secrets/secrets.yaml` and the VPS filesystem can decrypt mail, so the
primary protection this buys you is against a compromised backup or
stolen disk image without the sops key.

**First-time bootstrap** (run once after `colmena apply` enables the plugin):

```bash
nix run .#mail-admin -- all
```

Press `b` at each mailbox prompt to run `bootstrap-key`, which generates
a fresh random `cryptPassword` in sops (if missing) and then generates
the on-disk key wrapped with it (or verifies an existing key still
unwraps). `larry@` and `dan@` would auto-generate a key on first IMAP
login anyway, but `catchall@` and `ghost@` are real mailboxes nobody
logs into interactively, so the walker is the simplest way to bootstrap
every mailbox in one pass. Shared aliases (`support@`, `sales@`,
`hello@`) are rewritten by Postfix to `larry@` / `dan@` before LMTP
delivery, so they inherit those users' keys — no separate bootstrap
needed.

After bootstrap, `colmena apply mayday-vps` to ship the new
`cryptPassword` entries so dovecot can unwrap keys on future IMAP
sessions.

**Drift recovery** — if the sops `cryptPassword` and the on-disk key are
out of sync (e.g., after a manual sops edit or restoring a stale
backup):

```bash
nix run .#mail-admin -- bootstrap-key larry
```

Idempotent: verifies the current sops password unwraps the existing
key, or generates a fresh key if none exists. If the key exists but
won't unwrap with the sops password, the tool errors out — recover by
restoring the correct sops value from git history or by wiping the
mailbox's on-disk key and re-bootstrapping (destroys any mail
encrypted under the old key).

### DKIM — two-pass deploy

The DKIM key is generated by Rspamd on first mailserver deploy. Cloudflare
needs to publish the matching `mail._domainkey` TXT record, so the flow is:

1. First `tofu apply` (DKIM record skipped while `TF_VAR_dkim_public_key` is empty).
2. `colmena apply mayday-vps` — generates `/var/dkim/maydayelectronics.com.mail.txt`.
3. `nix run .#update-dkim-key` — SSHes to the VPS, extracts the key, writes it to `secrets/secrets.yaml` at `dkim.public_key`.
4. `exit` and re-enter `nix develop` so the updated `TF_VAR_dkim_public_key` exports.
5. Second `tofu apply` — publishes the DKIM TXT record.

### Ghost → local Postfix

`services.ghost-cms.{smtpHost,smtpPort,smtpServername,mailFrom}` in
`configuration.nix` wires Ghost's transactional mail (invites, password
resets, member magic links) through Postfix on `127.0.0.1:587`.
`smtpServername` tells nodemailer to expect `mx.maydayelectronics.com` in
the TLS cert even though we dial loopback — without it, STARTTLS fails
hostname verification.

**Ghost bulk/newsletter email is separate** and still hardcoded to
Mailgun's HTTP API in Ghost core. The SMTP config only covers
transactional mail.

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
  smtp_user: …         # ghost@maydayelectronics.com (plaintext, for nodemailer)
  smtp_password: …     # plaintext copy of ghost@ password
restic:
  password: …          # restic repo password
mail:
  larry:
    hashedPassword: $2b$…     # bcrypt; IMAP login, managed via mail-admin set-password
    cryptPassword: …          # random; wraps on-disk crypt key, managed via mail-admin bootstrap-key
  dan:      { hashedPassword: …, cryptPassword: … }
  ghost:    { hashedPassword: …, cryptPassword: … }
  catchall: { hashedPassword: …, cryptPassword: … }
dkim:
  public_key: "v=DKIM1; k=rsa; p=…"     # managed via update-dkim-key
```

Map of Ghost-related YAML paths → module secret names lives in
`configuration.nix::services.ghost-cms.sopsSecretPaths`. Mail
hashedPassword paths are declared in `mailserver.nix`.
