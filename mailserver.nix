{ config, ... }:
let
  sharedAliases = [
    "support@maydayelectronics.com"
    "sales@maydayelectronics.com"
    "hello@maydayelectronics.com"
  ];
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

  services.restic.backups.ghost-cms.paths = [ "/var/vmail" ];

  sops.secrets = {
    "mail/larry/hashedPassword" = { };
    "mail/dan/hashedPassword" = { };
    "mail/ghost/hashedPassword" = { };
    "mail/catchall/hashedPassword" = { };
  };
}
