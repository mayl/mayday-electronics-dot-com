{ pkgs,
  lib,
  ... }:
{
  nixpkgs.system = "x86_64-linux";
  networking.hostName = "mayday-vps";
  system.name = "mayday-vps";
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  programs.mosh.enable = true;
  environment.systemPackages = with pkgs; [ gitMinimal ];
  nix.settings = {
    trusted-users = [ "@wheel" ];
    experimental-features = [ "nix-command" "flakes" ];
  };
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  environment.systemPackages = with pkgs; [
    magic-wormhole #for moving wg0.key over
    wireguard-tools #for checking wg status
  ];
}
