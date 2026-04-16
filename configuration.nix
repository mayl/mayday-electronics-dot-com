{
  pkgs,
  lib,
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
    magic-wormhole # for moving wg0.key over
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

  services.nginx = {
    enable = true;
    virtualHosts."maydayelectronics.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        root = pkgs.writeTextDir "index.html" ''
          <!DOCTYPE html>
          <html>
            <head><title>Mayday Electronics</title></head>
            <body>
              <h1>Hello from Mayday Electronics!</h1>
              <p>VPS is up and colmena deploy works.</p>
            </body>
          </html>
        '';
      };
    };
  };
}
