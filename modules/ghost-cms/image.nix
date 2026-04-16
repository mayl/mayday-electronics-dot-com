{ dockerTools }:

dockerTools.pullImage {
  imageName = "ghost";
  imageDigest = "sha256:f74b0baaa601dcc073040f4431d0000af79dc9b70a2d458693478198282aa817";
  hash = "sha256-xEAuXiaMHzsk9vaBkS/h0kUqcETtwqCBOop7wxHmIPc=";
  finalImageName = "ghost";
  finalImageTag = "6-alpine";
}
