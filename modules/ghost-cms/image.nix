{ dockerTools }:

dockerTools.pullImage {
  imageName = "ghost";
  imageDigest = "sha256:db1c0b7906991b8ca34ca1ed4f1598afafb895dd1d7d6bc9bf6f3bedf56cd6d3";
  hash = "sha256-uyIdA9Bkqx+pRKyrMnd6itEGTC++MP36IKbjAKOBkTo=";
  finalImageName = "ghost";
  finalImageTag = "6-alpine";
}
