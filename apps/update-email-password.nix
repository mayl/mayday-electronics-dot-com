{
  writeShellApplication,
  mkpasswd,
  sops,
}:
writeShellApplication {
  name = "update-email-password";
  runtimeInputs = [
    mkpasswd
    sops
  ];
  text = ''
    if [[ ! -f flake.nix ]]; then
      echo "error: run from the flake root (expected ./flake.nix)" >&2
      exit 1
    fi

    export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/mayday-vps.txt}"

    if [[ $# -ne 1 ]]; then
      echo "usage: nix run .#update-email-password -- <mailbox>" >&2
      echo "  mailbox: larry | dan | ghost | catchall" >&2
      exit 2
    fi

    mailbox=$1
    case "$mailbox" in
      larry|dan|ghost|catchall) ;;
      *)
        echo "error: unknown mailbox '$mailbox'" >&2
        echo "  valid: larry dan ghost catchall" >&2
        exit 2
        ;;
    esac

    read -rsp "Password for ''${mailbox}@maydayelectronics.com: " pw1
    echo
    read -rsp "Confirm: " pw2
    echo

    if [[ -z "$pw1" ]]; then
      echo "error: empty password" >&2
      exit 1
    fi

    if [[ "$pw1" != "$pw2" ]]; then
      echo "error: passwords do not match" >&2
      exit 1
    fi

    hash=$(mkpasswd -s -m bcrypt <<<"$pw1")

    sops set secrets/secrets.yaml "[\"mail\"][\"''${mailbox}\"][\"hashedPassword\"]" "\"''${hash}\""
    echo "Updated mail/''${mailbox}/hashedPassword in secrets/secrets.yaml"

    if [[ "$mailbox" == "ghost" ]]; then
      sops set secrets/secrets.yaml '["ghost"]["smtp_user"]' '"ghost@maydayelectronics.com"'
      sops set secrets/secrets.yaml '["ghost"]["smtp_password"]' "\"''${pw1}\""
      echo "Also updated ghost.smtp_user and ghost.smtp_password (plaintext) for Ghost container SMTP auth."
    fi

    echo "Run 'colmena apply mayday-vps' to deploy."
  '';
}
