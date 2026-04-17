{
  description = "Mayday Electronics VPS infrastructure";

  inputs = {
    colmena.url = "github:zhaofengli/colmena";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    simple-nixos-mailserver = {
      url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-25.11";
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
            update-ghost-image = {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "update-ghost-image";
                  runtimeInputs = [ pkgs.nix-prefetch-docker ];
                  text = builtins.readFile ./apps/update-ghost-image.sh;
                }
              }/bin/update-ghost-image";
            };
            generate-mail-hash = {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "generate-mail-hash";
                  runtimeInputs = [ pkgs.mkpasswd ];
                  text = "exec mkpasswd -m bcrypt";
                }
              }/bin/generate-mail-hash";
            };
            update-email-password = {
              type = "app";
              program = pkgs.lib.getExe self'.packages.update-email-password;
            };
            update-dkim-key = {
              type = "app";
              program = pkgs.lib.getExe self'.packages.update-dkim-key;
            };
            edit-dev-secrets = {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  name = "edit-dev-secrets";
                  runtimeInputs = [ pkgs.sops ];
                  text = ''
                    if [[ ! -f flake.nix ]]; then
                      echo "error: run from the flake root" >&2
                      exit 1
                    fi
                    export SOPS_AGE_KEY_FILE="$PWD/secrets/dev-age-key.txt"
                    exec sops secrets/dev-secrets.yaml
                  '';
                }
              }/bin/edit-dev-secrets";
            };
          };
          packages = {
            vm = inputs.self.nixosConfigurations.mayday-vps-vm.config.system.build.vm;
            ghost-image = pkgs.callPackage ./modules/ghost-cms/image.nix { };
            update-email-password = pkgs.callPackage ./apps/update-email-password.nix { };
            update-dkim-key = pkgs.callPackage ./apps/update-dkim-key.nix { };
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
              swaks
              inputs'.colmena.packages.colmena
              config.treefmt.build.wrapper
            ];
            shellHook = ''
                          export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/mayday-vps.txt}"
                          echo "Exporting B2 Access Keys for OpenTofu state backend..."
                          export TF_VAR_B2_STATE_ACCESS_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["access_key"]' ${inputs.self}/secrets/secrets.yaml)
                          export TF_VAR_B2_STATE_SECRET_KEY=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["b2"]["tf_state"]["secret_key"]' ${inputs.self}/secrets/secrets.yaml)
                          export TF_VAR_ssh_public_key=$(cat ${inputs.larrySSH.outPath})
                          export TF_VAR_dkim_public_key=$(${pkgs.lib.getExe pkgs.sops} -d --extract '["dkim"]["public_key"]' ${inputs.self}/secrets/secrets.yaml 2>/dev/null || echo "")
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
          ghost-cms = ./modules/ghost-cms;
          mayday-vps-config = {
            _module.args = { inherit inputs; };
            imports = [
              ./configuration.nix
              inputs.self.nixosModules.ghost-cms
              inputs.sops-nix.nixosModules.sops
              inputs.simple-nixos-mailserver.nixosModules.default
              (
                { pkgs, ... }:
                {
                  services.ghost-cms.imageFile = pkgs.callPackage ./modules/ghost-cms/image.nix { };
                }
              )
            ];
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
              { lib, pkgs, ... }:
              {
                users.users.root.initialPassword = "root";
                virtualisation.diskSize = 8192;
                virtualisation.memorySize = 2048;
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
                  {
                    from = "host";
                    host.port = 2525;
                    guest.port = 25;
                  }
                  {
                    from = "host";
                    host.port = 4465;
                    guest.port = 465;
                  }
                  {
                    from = "host";
                    host.port = 5587;
                    guest.port = 587;
                  }
                  {
                    from = "host";
                    host.port = 9993;
                    guest.port = 993;
                  }
                ];
                services.ghost-cms = {
                  tls = lib.mkForce false;
                  domain = lib.mkForce "localhost";
                  url = lib.mkForce "http://localhost:8080";
                };
                mailserver.certificateScheme = lib.mkForce "selfsigned";
                networking.extraHosts = ''
                  127.0.0.1 mx.maydayelectronics.com
                '';
                environment.systemPackages = [ pkgs.swaks ];
                sops.age.keyFile = lib.mkForce "/etc/sops-nix-dev/key.txt";
                sops.defaultSopsFile = lib.mkForce ./secrets/dev-secrets.yaml;
                environment.etc."sops-nix-dev/key.txt" = {
                  source = ./secrets/dev-age-key.txt;
                  mode = "0400";
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
              keys."sops-age-key" = {
                keyFile = "/home/larry/.config/sops/age/mayday-vps.txt";
                destDir = "/var/lib/sops-nix";
                name = "key.txt";
                user = "root";
                group = "root";
                permissions = "0400";
                uploadAt = "pre-activation";
              };
            };
            imports = [ inputs.self.nixosModules.mayday-vps ];
          };
        };
      };
    };
}
