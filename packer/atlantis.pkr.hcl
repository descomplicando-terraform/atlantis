packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  ami_name  = "${var.ami_prefix}-${var.atlantis_version}-${local.timestamp}"
}

source "amazon-ebs" "atlantis" {
  region        = var.aws_region
  instance_type = var.instance_type

  ami_name        = local.ami_name
  ami_description = "Atlantis ${var.atlantis_version} nativo - configuracao via SSM Parameter Store"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  ssh_username = "ubuntu"

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  associate_public_ip_address = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  imds_support = "v2.0"
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name             = local.ami_name
    Component        = "atlantis"
    AtlantisVersion  = var.atlantis_version
    TerraformVersion = var.terraform_version
    BaseOS           = "ubuntu-24.04"
    BuiltBy          = "packer"
    BuildDate        = local.timestamp
  }

  run_tags = {
    Name = "packer-builder-${local.ami_name}"
  }

  snapshot_tags = {
    Name = local.ami_name
  }
}

build {
  name    = "atlantis"
  sources = ["source.amazon-ebs.atlantis"]

  provisioner "shell" {
    inline = [
      "echo 'Aguardando cloud-init terminar...'",
      "cloud-init status --wait || true",
    ]
  }

  provisioner "ansible" {
    playbook_file = "${path.root}/../ansible/playbook.yml"
    user          = "ubuntu"

    extra_arguments = [
      "--extra-vars", "atlantis_version=${var.atlantis_version}",
      "--extra-vars", "terraform_version=${var.terraform_version}",
      "--extra-vars", "atlantis_port=${var.atlantis_port}",
      "--extra-vars", "atlantis_ssm_parameter=${var.atlantis_ssm_parameter}",
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_NOCOWS=1",
      "ANSIBLE_PIPELINING=True",
      "ANSIBLE_CONFIG=${path.root}/../ansible/ansible.cfg",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/cleanup.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      atlantis_version = var.atlantis_version
      ssm_parameter    = var.atlantis_ssm_parameter
    }
  }
}
