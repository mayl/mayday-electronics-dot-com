{
  description = "Description for the project";

  inputs = {
    colmena.url = "github:zhaofengli/colmena";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    larrySSH = {
      url = "https://github.com/mayl.keys";
      flake = false;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      perSystem = { config, self', inputs', pkgs, system, ... }: {
        apps.nixos-anywhere-script.program = "${self'.packages.anywhereScript}";
        packages = {
          anywhereScript = ((pkgs.writers.writeBash "setupSff" ''
            ${pkgs.lib.getExe pkgs.nix} run --refresh github:nix-community/nixos-anywhere -- --flake .#mayday-vps --target-host root@$1
          '').overrideAttrs { pname = "nixos-anywhere-host"; });
        };
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            opentofu
            sops
            inputs'.colmena.packages.colmena
          ];
          shellHook = ''
            echo "Exporting B2 Access Keys for OpenTofu state backend..."
            export TF_VAR_B2_STATE_ACCESS_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["access_key"]' ${inputs.self}/secrets/secrets.yaml)
            export TF_VAR_B2_STATE_SECRET_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["secret_key"]' ${inputs.self}/secrets/secrets.yaml)
            export TF_VAR_ssh_public_key=$(cat ${inputs.larrySSH.outPath})
            echo "Done."
          '';
        };
      };
      flake = {
        nixosModules = {
          mayday-vps-config = {
            imports = [
              inputs.disko.nixosModules.disko
              ./configuration.nix
              ./disk-config.nix
              ./hardware.nix
              { users.users.root.openssh.authorizedKeys.keyFiles = [ inputs.larrySSH.outPath ]; }
            ];
          };
        };
        nixosConfigurations.mayday-vps = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ inputs.self.nixosModules.mayday-vps-config ];
        };
        colmenaHive = inputs.colmena.lib.makeHive {
          meta = {
            nixpkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
          };
          mayday-vps = {
            deployment = {
              targetHost = "maydayelectronics.com";
              targetUser = "root";
            };
            imports = [ inputs.self.nixosModules.mayday-vps-config ];
          };
        };
      };
    };
}
