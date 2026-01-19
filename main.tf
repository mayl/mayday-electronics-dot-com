variable B2_STATE_ACCESS_KEY { type = string }
variable B2_STATE_SECRET_KEY { type = string }

terraform {
  backend "s3" {
    skip_credentials_validation = true
    skip_metadata_api_check = true
    skip_requesting_account_id = true
    skip_region_validation = true
    endpoints = {
      s3 = "https://s3.us-west-000.backblazeb2.com"
    }
    region = "us-west-000"
    bucket = "maydayelectronics-dot-com-tf-state"
    key = "opentofu-state/terraform.tfstate"
    access_key = "${var.B2_STATE_ACCESS_KEY}"
    secret_key = "${var.B2_STATE_SECRET_KEY}"
  }

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = "5.15.0"
    }
    vultr = {
      source = "vultr/vultr"
      version = "2.28.0"
    }
    namecheap = {
      source = "namecheap/namecheap"
      version = "2.2.0"
    }
    sops = {
      source = "carlpett/sops"
      version = "1.3.0"
    }
  }
}

provider "sops" {}

data "sops_file" "secrets" { 
  source_file = "secrets/secrets.yaml"
}

provider "vultr" {
  api_key = data.sops_file.secrets.data["vultr_api"]
  rate_limit = 100
  retry_limit = 3
}

resource "vultr_instance" "web" {
  label = "Mayday VPS"
  region = "ewr"
  plan = "vc2-1c-2gb"
}
