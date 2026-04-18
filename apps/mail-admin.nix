{
  lib,
  writers,
  python3Packages,
  sops,
  openssh,
}:
writers.writePython3Bin "mail-admin" {
  libraries = [ python3Packages.bcrypt ];
  flakeIgnore = [
    "E501"
    "W503"
  ];
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      sops
      openssh
    ])
  ];
} ./mail-admin.py
