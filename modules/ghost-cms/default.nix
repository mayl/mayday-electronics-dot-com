{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ghost-cms;
in
{
  options.services.ghost-cms = {
    enable = lib.mkEnableOption "Ghost CMS via OCI container with native MySQL and B2 backups";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "blog.example.com";
      description = "Fully-qualified domain for the nginx vhost.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "${if cfg.tls then "https" else "http"}://${cfg.domain}";
      defaultText = lib.literalExpression ''"https://''${cfg.domain}" (http when tls = false)'';
      description = "Canonical URL Ghost emits in links. Override for local VM (e.g. http://localhost:8080).";
    };

    tls = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ACME + forceSSL on the nginx vhost. Set false for local VM.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Per-vhost ACME email. If null, inherits security.acme.defaults.email.";
    };

    imageFile = lib.mkOption {
      type = lib.types.package;
      description = "Pinned Ghost OCI image (from pkgs.dockerTools.pullImage).";
    };

    imageRef = lib.mkOption {
      type = lib.types.str;
      default = "ghost:6-alpine";
      description = "Image reference string passed to podman (must match the imageFile).";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ghost-cms";
      description = "Host directory for Ghost content (themes, images, settings).";
    };

    backup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        description = "B2 bucket name for the restic repo.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "s3.us-west-000.backblazeb2.com";
        description = "S3-compatible endpoint (default: Backblaze us-west).";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar spec.";
      };
      pruneOpts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
    };

    sopsSecretPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = ''
        Map of purpose → sops-nix secret name. Required keys: dbPassword,
        resticPassword, backupAccessKey, backupSecretKey, smtpUser,
        smtpPassword.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    swapDevices = [
      {
        device = "/var/swapfile";
        size = 2048;
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
      "d ${cfg.stateDir}/content 0750 1000 1000 -"
      "d /var/backup/mysql 0700 mysqlbackup mysqlbackup -"
    ];

    services.mysql = {
      enable = true;
      package = pkgs.mysql80;
      ensureDatabases = [ "ghost" ];
      settings.mysqld = {
        bind-address = "127.0.0.1";
        innodb_buffer_pool_size = "128M";
      };
    };

    systemd.services.ghost-db-setup = {
      description = "Create Ghost MySQL user with password from SOPS secret";
      after = [ "mysql.service" ];
      requires = [ "mysql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        password=$(cat ${config.sops.secrets.${cfg.sopsSecretPaths.dbPassword}.path})
        ${pkgs.mysql80}/bin/mysql --protocol=socket -u root <<SQL
        CREATE USER IF NOT EXISTS 'ghost'@'127.0.0.1' IDENTIFIED BY '$password';
        ALTER USER 'ghost'@'127.0.0.1' IDENTIFIED BY '$password';
        GRANT ALL PRIVILEGES ON ghost.* TO 'ghost'@'127.0.0.1';
        FLUSH PRIVILEGES;
        SQL
      '';
    };

    sops.secrets = {
      ${cfg.sopsSecretPaths.dbPassword} = { };
      ${cfg.sopsSecretPaths.resticPassword} = { };
      ${cfg.sopsSecretPaths.backupAccessKey} = { };
      ${cfg.sopsSecretPaths.backupSecretKey} = { };
      ${cfg.sopsSecretPaths.smtpUser} = { };
      ${cfg.sopsSecretPaths.smtpPassword} = { };
    };

    sops.templates."ghost-cms.env".content = ''
      database__connection__password=${config.sops.placeholder.${cfg.sopsSecretPaths.dbPassword}}
      mail__options__auth__user=${config.sops.placeholder.${cfg.sopsSecretPaths.smtpUser}}
      mail__options__auth__pass=${config.sops.placeholder.${cfg.sopsSecretPaths.smtpPassword}}
    '';

    sops.templates."ghost-cms-restic.env".content = ''
      AWS_ACCESS_KEY_ID=${config.sops.placeholder.${cfg.sopsSecretPaths.backupAccessKey}}
      AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.${cfg.sopsSecretPaths.backupSecretKey}}
    '';

    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.ghost = {
      image = cfg.imageRef;
      imageFile = cfg.imageFile;
      extraOptions = [ "--network=host" ];
      environment = {
        url = cfg.url;
        database__client = "mysql";
        database__connection__host = "127.0.0.1";
        database__connection__port = "3306";
        database__connection__user = "ghost";
        database__connection__database = "ghost";
        server__host = "127.0.0.1";
        server__port = "2368";
        mail__transport = "SMTP";
        mail__options__host = "";
        mail__options__port = "587";
        mail__options__secure = "false";
      };
      environmentFiles = [ config.sops.templates."ghost-cms.env".path ];
      volumes = [ "${cfg.stateDir}/content:/var/lib/ghost/content" ];
    };

    systemd.services.podman-ghost = {
      after = [ "ghost-db-setup.service" ];
      requires = [ "ghost-db-setup.service" ];
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.domain} = {
        enableACME = cfg.tls;
        forceSSL = cfg.tls;
        locations."/" = {
          proxyPass = "http://127.0.0.1:2368";
          proxyWebsockets = true;
        };
      };
    };

    security.acme.certs = lib.mkIf (cfg.tls && cfg.acmeEmail != null) {
      ${cfg.domain}.email = cfg.acmeEmail;
    };

    services.mysqlBackup = lib.mkIf cfg.backup.enable {
      enable = true;
      databases = [ "ghost" ];
      location = "/var/backup/mysql";
      singleTransaction = true;
    };

    systemd.timers.mysql-backup = lib.mkIf cfg.backup.enable {
      wantedBy = lib.mkForce [ ];
    };

    services.restic.backups.ghost-cms = lib.mkIf cfg.backup.enable {
      paths = [
        "/var/backup/mysql"
        "${cfg.stateDir}/content"
      ];
      repository = "s3:${cfg.backup.endpoint}/${cfg.backup.bucket}";
      passwordFile = config.sops.secrets.${cfg.sopsSecretPaths.resticPassword}.path;
      environmentFile = config.sops.templates."ghost-cms-restic.env".path;
      initialize = true;
      pruneOpts = cfg.backup.pruneOpts;
      backupPrepareCommand = "${pkgs.systemd}/bin/systemctl start --wait mysql-backup.service";
      timerConfig = {
        OnCalendar = cfg.backup.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
