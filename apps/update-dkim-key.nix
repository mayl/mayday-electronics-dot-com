{
  writeShellApplication,
  openssh,
  sops,
}:
writeShellApplication {
  name = "update-dkim-key";
  runtimeInputs = [
    openssh
    sops
  ];
  text = ''
    if [[ ! -f flake.nix ]]; then
      echo "error: run from the flake root (expected ./flake.nix)" >&2
      exit 1
    fi

    export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/mayday-vps.txt}"

    host="''${1:-root@maydayelectronics.com}"
    remote_file=/var/dkim/maydayelectronics.com.mail.txt

    echo "Fetching DKIM public key from $host:$remote_file..."
    key=$(ssh -o BatchMode=yes "$host" "grep -oE '\"[^\"]*\"' $remote_file | tr -d '\"\n'")

    if [[ -z "$key" ]]; then
      echo "error: DKIM key is empty (is the mailserver deployed and has it generated the key?)" >&2
      exit 1
    fi

    if [[ "$key" != v=DKIM1* ]]; then
      echo "error: extracted value doesn't look like a DKIM record (expected v=DKIM1...):" >&2
      echo "  $key" >&2
      exit 1
    fi

    echo "Extracted key ($(echo -n "$key" | wc -c) bytes)."
    printf '"%s"' "$key" | sops set --value-stdin secrets/secrets.yaml '["dkim"]["public_key"]'
    echo "Wrote dkim.public_key to secrets/secrets.yaml."
    echo "Next: exit and re-enter the devshell (so TF_VAR_dkim_public_key refreshes), then 'tofu apply'."
  '';
}
