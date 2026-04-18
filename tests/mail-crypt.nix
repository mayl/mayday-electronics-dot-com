{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "mail-crypt";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ self.nixosModules.mayday-vps-config ];

      mailserver.certificateScheme = lib.mkForce "selfsigned";
      networking.extraHosts = ''
        127.0.0.1 mx.maydayelectronics.com
      '';
      services.ghost-cms = {
        tls = lib.mkForce false;
        domain = lib.mkForce "localhost";
        url = lib.mkForce "http://localhost:8080";
      };
      sops.age.keyFile = lib.mkForce "/etc/sops-nix-dev/key.txt";
      sops.defaultSopsFile = lib.mkForce ../secrets/dev-secrets.yaml;
      environment.etc."sops-nix-dev/key.txt" = {
        source = ../secrets/dev-age-key.txt;
        mode = "0400";
      };

      environment.systemPackages = [
        pkgs.swaks
        pkgs.sops
        pkgs.jq
        (pkgs.python3.withPackages (ps: [ ps.bcrypt ]))
        self.packages.${pkgs.stdenv.hostPlatform.system}.mail-admin
      ];

      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    import json
    import shlex

    SOPS_FILE_REL = "secrets/dev-secrets.yaml"
    REPO = "/tmp/repo"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("postfix.service")
    machine.wait_for_unit("dovecot2.service")
    machine.wait_for_unit("sshd.service")
    machine.wait_for_open_port(22)
    machine.wait_for_open_port(25)
    machine.wait_for_open_port(993)

    # --- SSH self-access so mail-admin's `ssh root@localhost doveadm ...` works ---
    machine.succeed("mkdir -p /root/.ssh")
    machine.succeed("ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519")
    machine.succeed("install -m 600 /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys")
    machine.succeed("ssh-keyscan -H localhost >> /root/.ssh/known_hosts 2>/dev/null")
    machine.succeed("ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@localhost true")

    # --- Stage a mutable repo copy so sops writes don't touch the store ---
    machine.succeed(f"mkdir -p {REPO}/secrets")
    machine.succeed(f"touch {REPO}/flake.nix")
    machine.succeed(f"cp ${../secrets/dev-secrets.yaml} {REPO}/{SOPS_FILE_REL}")
    machine.succeed(f"cp ${../.sops.yaml} {REPO}/.sops.yaml")
    machine.succeed(f"chmod u+w {REPO}/{SOPS_FILE_REL}")

    ENV_PREFIX = (
        "env REMOTE_HOST=root@localhost REMOTE_PORT=22 "
        f"SOPS_FILE={SOPS_FILE_REL} "
        "SOPS_AGE_KEY_FILE=/etc/sops-nix-dev/key.txt"
    )

    def mail_admin(args, stdin=""):
        pipe = f"printf %s {shlex.quote(stdin)} | " if stdin else ""
        return machine.succeed(
            f"cd {REPO} && {pipe}{ENV_PREFIX} mail-admin {args} 2>&1"
        )

    def mail_admin_fail(args, stdin=""):
        pipe = f"printf %s {shlex.quote(stdin)} | " if stdin else ""
        return machine.fail(
            f"cd {REPO} && {pipe}{ENV_PREFIX} mail-admin {args} 2>&1"
        )

    def sops_get(path):
        return machine.succeed(
            f"cd {REPO} && {ENV_PREFIX} sops -d --extract "
            f"{shlex.quote(path)} {SOPS_FILE_REL}"
        ).strip()

    def sops_set(path, value):
        machine.succeed(
            f"cd {REPO} && printf %s {shlex.quote(json.dumps(value))} | "
            f"{ENV_PREFIX} sops set --value-stdin {SOPS_FILE_REL} "
            f"{shlex.quote(path)}"
        )

    with subtest("bootstrap-key: either generates or verifies a key for larry"):
        # Dovecot may have auto-generated the key during userdb init (it has the
        # cryptPassword via userdb-extras), so either path is valid here.
        out = mail_admin("bootstrap-key larry")
        assert "crypt key" in out, out

    with subtest("bootstrap-key idempotent: second call verifies existing key"):
        out = mail_admin("bootstrap-key larry")
        assert "verified existing crypt key" in out, out

    with subtest("LMTP delivery writes encrypted file; doveadm fetch returns plaintext"):
        machine.succeed(
            "swaks --to larry@maydayelectronics.com --from test@example.com "
            "--server localhost:25 --body secret-payload-xyzzy --suppress-data"
        )
        # Wait for delivery to settle:
        machine.wait_until_succeeds(
            "find /var/vmail/maydayelectronics.com/larry -type f -name '*,S=*' | grep -q ."
        )
        msg_path = machine.succeed(
            "find /var/vmail/maydayelectronics.com/larry -type f -name '*,S=*' | head -1"
        ).strip()
        magic = machine.succeed(f"head -c 7 {shlex.quote(msg_path)}").strip()
        assert magic == "CRYPTED", f"expected CRYPTED magic, got {magic!r}"
        rc, _ = machine.execute(f"grep -a -q secret-payload-xyzzy {shlex.quote(msg_path)}")
        assert rc != 0, "plaintext payload leaked to disk"
        fetched = machine.succeed(
            "doveadm fetch -u larry@maydayelectronics.com body mailbox INBOX ALL"
        )
        assert "secret-payload-xyzzy" in fetched, f"payload not in fetch:\n{fetched}"

    with subtest("set-password larry: new bcrypt hash written to sops"):
        original_hash = sops_get('["mail"]["larry"]["hashedPassword"]')
        mail_admin("set-password larry", stdin="newpass-larry\nnewpass-larry\n")
        new_hash = sops_get('["mail"]["larry"]["hashedPassword"]')
        assert new_hash != original_hash, "hash was not rewritten"
        assert new_hash.startswith("$2"), f"not a bcrypt hash: {new_hash!r}"
        machine.succeed(
            "python3 -c "
            + shlex.quote(
                f"import bcrypt,sys; sys.exit(0 if bcrypt.checkpw(b'newpass-larry', {new_hash!r}.encode()) else 1)"
            )
        )

    with subtest("set-password ghost also rewrites ghost.smtp_user / smtp_password"):
        mail_admin("set-password ghost", stdin="ghostpw\nghostpw\n")
        assert sops_get('["ghost"]["smtp_user"]') == "ghost@maydayelectronics.com"
        assert sops_get('["ghost"]["smtp_password"]') == "ghostpw"

    with subtest("all walker: 4× skip exits cleanly"):
        mail_admin("all", stdin="s\ns\ns\ns\n")

    with subtest("bootstrap-key drift: sops cryptPassword diverges from on-disk key"):
        original_crypt = sops_get('["mail"]["larry"]["cryptPassword"]')
        sops_set('["mail"]["larry"]["cryptPassword"]', "wrong-password")
        err = mail_admin_fail("bootstrap-key larry")
        assert "does not unwrap" in err, f"expected drift error, got:\n{err}"
        sops_set('["mail"]["larry"]["cryptPassword"]', original_crypt)
  '';
}
