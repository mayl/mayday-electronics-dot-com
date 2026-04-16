{
  pkgs,
  lib,
  inputs,
  ...
}:
{
  nixpkgs.system = "x86_64-linux";
  networking.hostName = "mayday-vps";
  system.name = "mayday-vps";
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ inputs.larrySSH.outPath ];
  programs.mosh.enable = true;
  nix.settings = {
    trusted-users = [ "@wheel" ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  environment.systemPackages = with pkgs; [
    gitMinimal
    magic-wormhole # for moving wg0.key / sops age key over
    wireguard-tools # for checking wg status
  ];

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  systemd.tmpfiles.rules = [
    "d /var/log/nginx 0750 nginx nginx -"
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "larry@maydayelectronics.com";
  };

  services.nginx.enable = true;

  sops.defaultSopsFile = ./secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  services.ghost-cms = {
    enable = true;
    domain = "maydayelectronics.com";
    backup.bucket = "mayday-electronics-dot-com-backup";
    sopsSecretPaths = {
      dbPassword = "ghost/db_password";
      resticPassword = "restic/password";
      backupAccessKey = "b2/backup/access_key";
      backupSecretKey = "b2/backup/secret_key";
      smtpUser = "ghost/smtp_user";
      smtpPassword = "ghost/smtp_password";
    };
  };
}
