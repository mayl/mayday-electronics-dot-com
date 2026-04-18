{ config, lib, ... }:
let
  sharedAliases = [
    "support@maydayelectronics.com"
    "sales@maydayelectronics.com"
    "hello@maydayelectronics.com"
  ];
  cryptMailboxes = map (addr: lib.head (lib.splitString "@" addr)) (
    lib.attrNames config.mailserver.loginAccounts
  );
in
{
  mailserver = {
    enable = true;
    stateVersion = 3;
    fqdn = "mx.maydayelectronics.com";
    domains = [ "maydayelectronics.com" ];

    loginAccounts = {
      "larry@maydayelectronics.com" = {
        hashedPasswordFile = config.sops.secrets."mail/larry/hashedPassword".path;
        aliases = [
          "postmaster@maydayelectronics.com"
          "abuse@maydayelectronics.com"
          "hostmaster@maydayelectronics.com"
        ]
        ++ sharedAliases;
      };
      "dan@maydayelectronics.com" = {
        hashedPasswordFile = config.sops.secrets."mail/dan/hashedPassword".path;
        aliases = sharedAliases;
      };
      "ghost@maydayelectronics.com".hashedPasswordFile =
        config.sops.secrets."mail/ghost/hashedPassword".path;
      "catchall@maydayelectronics.com" = {
        hashedPasswordFile = config.sops.secrets."mail/catchall/hashedPassword".path;
        catchAll = [ "maydayelectronics.com" ];
      };
    };

    certificateScheme = "acme-nginx";
    mailDirectory = "/var/vmail";
    dkimKeyBits = 2048;
    dkimSelector = "mail";
    useFsLayout = true;
    enableSubmission = true;
    enableSubmissionSsl = true;
  };

  services.dovecot2.mailPlugins.globally.enable = [ "mail_crypt" ];
  services.dovecot2.extraConfig = lib.mkBefore ''
    userdb {
      driver = passwd-file
      args = ${config.sops.templates."mail-userdb-extras".path}
      result_success = continue
      result_failure = continue
      result_internalfail = continue
    }
    mail_attribute_dict = file:/var/vmail/%d/%n/dovecot-attributes
    plugin {
      mail_crypt_save_version = 2
      mail_crypt_require_encrypted_user_key = yes
      mail_crypt_curve = secp521r1
    }
  '';

  services.restic.backups.ghost-cms.paths = [ "/var/vmail" ];

  sops.secrets = lib.listToAttrs (
    lib.concatMap (mbx: [
      {
        name = "mail/${mbx}/hashedPassword";
        value = { };
      }
      {
        name = "mail/${mbx}/cryptPassword";
        value = { };
      }
    ]) cryptMailboxes
  );

  sops.templates."mail-userdb-extras" = {
    mode = "0440";
    owner = "root";
    group = "dovecot2";
    content = lib.concatMapStringsSep "\n" (
      mbx:
      "${mbx}@maydayelectronics.com:::::::userdb_mail_crypt_private_password=${
        config.sops.placeholder."mail/${mbx}/cryptPassword"
      }"
    ) cryptMailboxes;
  };
}
