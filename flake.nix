{
  description = "Mayday Electronics VPS infrastructure";

  inputs = {
    colmena.url = "github:zhaofengli/colmena";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    larrySSH = {
      url = "https://github.com/mayl.keys";
      flake = false;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        {
          treefmt.config = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            settings.formatter.opentofu = {
              command = pkgs.lib.getExe pkgs.opentofu;
              options = [ "fmt" ];
              includes = [ "*.tf" ];
            };
          };
          apps = {
            nixos-anywhere-script.program = "${self'.packages.anywhereScript}";
            vm = {
              type = "app";
              program = "${self'.packages.vm}/bin/run-mayday-vps-vm";
            };
          };
          packages = {
            vm = inputs.self.nixosConfigurations.mayday-vps-vm.config.system.build.vm;
            anywhereScript = (
              (pkgs.writers.writeBash "mayday-vps-init" ''
                ${pkgs.lib.getExe pkgs.nix} run --refresh github:nix-community/nixos-anywhere -- --flake .#mayday-vps --target-host root@$1
              '').overrideAttrs
                { pname = "nixos-anywhere-host"; }
            );
          };
          devShells.default = pkgs.mkShell {
            buildInputs = with pkgs; [
              opentofu
              sops
              inputs'.colmena.packages.colmena
              config.treefmt.build.wrapper
            ];
            shellHook = ''
                          echo "Exporting B2 Access Keys for OpenTofu state backend..."
                          export TF_VAR_B2_STATE_ACCESS_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["access_key"]' ${inputs.self}/secrets/secrets.yaml)
                          export TF_VAR_B2_STATE_SECRET_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["secret_key"]' ${inputs.self}/secrets/secrets.yaml)
                          export TF_VAR_ssh_public_key=$(cat ${inputs.larrySSH.outPath})
                          echo "Done."
                          if [ ! -f .git/hooks/pre-commit ]; then
                            echo "Installing pre-commit formatting hook..."
                            cat > .git/hooks/pre-commit << 'HOOKEOF'
              #!/bin/sh
              treefmt --fail-on-change
              HOOKEOF
                            chmod +x .git/hooks/pre-commit
                          fi
            '';
          };
        };
      flake = {
        nixosModules = {
          mayday-vps-config = {
            _module.args = { inherit inputs; };
            imports = [ ./configuration.nix ];
          };
          mayday-vps = {
            imports = [
              inputs.self.nixosModules.mayday-vps-config
              inputs.disko.nixosModules.disko
              ./disk-config.nix
              ./hardware.nix
            ];
          };
        };
        nixosConfigurations.mayday-vps = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ inputs.self.nixosModules.mayday-vps ];
        };
        nixosConfigurations.mayday-vps-vm = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            inputs.self.nixosModules.mayday-vps-config
            "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
            (
              { lib, ... }:
              {
                users.users.root.initialPassword = "root";
                virtualisation.forwardPorts = [
                  {
                    from = "host";
                    host.port = 8080;
                    guest.port = 80;
                  }
                  {
                    from = "host";
                    host.port = 2222;
                    guest.port = 22;
                  }
                ];
                services.nginx.virtualHosts."maydayelectronics.com" = {
                  enableACME = lib.mkForce false;
                  forceSSL = lib.mkForce false;
                  serverAliases = [ "localhost" ];
                };
              }
            )
          ];
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
            imports = [ inputs.self.nixosModules.mayday-vps ];
          };
        };
      };
    };
}
