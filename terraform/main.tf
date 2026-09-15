

data "aws_ami" "atlantis" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["atlantis-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_eip" "atlantis" {
  domain = "vpc"
  tags   = { Name = "atlantis" }
}

resource "aws_eip_association" "atlantis" {
  instance_id   = module.atlantis.id
  allocation_id = aws_eip.atlantis.id
}

module "atlantis" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.4"

  name          = "atlantis"
  ami           = data.aws_ami.atlantis.id
  instance_type = var.instance_type
  key_name      = var.key_name

  associate_public_ip_address = true

  subnet_id = sort(data.aws_subnets.default.ids)[0]

  security_group_vpc_id = data.aws_vpc.default.id

  security_group_ingress_rules = {
    atlantis = {
      description = "UI e webhook do Atlantis"
      cidr_ipv4   = var.cidr_liberado
      from_port   = var.atlantis_port
      to_port     = var.atlantis_port
    }
    ssh = {
      description = "SSH para acompanhar os logs"
      cidr_ipv4   = var.cidr_liberado
      from_port   = 22
      to_port     = 22
    }
  }

  create_iam_instance_profile = true
  iam_role_policies = {
    ssm_read = aws_iam_policy.ssm_read.arn
  }

  metadata_options = {
    http_tokens = "required"
  }

  user_data = <<-EOT
    #!/bin/bash
    cat > /etc/atlantis/atlantis.conf <<CONF
    SSM_PARAMETER=${var.ssm_parameter}
    AWS_REGION=${var.region}
    AWS_DEFAULT_REGION=${var.region}
    ATLANTIS_PORT=${var.atlantis_port}
    ATLANTIS_ATLANTIS_URL=http://${aws_eip.atlantis.public_ip}:${var.atlantis_port}
    CONF
    systemctl restart atlantis-env.service atlantis.service
  EOT

  tags = {
    Component = "atlantis"
  }
}

resource "terraform_data" "espera_atlantis" {
  triggers_replace = [aws_eip_association.atlantis.id]

  provisioner "local-exec" {
    command = <<-EOT
      url="http://${aws_eip.atlantis.public_ip}:${var.atlantis_port}/healthz"
      for i in $(seq 1 60); do
        if curl -fsS -m 5 "$url" >/dev/null 2>&1; then
          echo "Atlantis no ar: $url"
          exit 0
        fi
        echo "aguardando o Atlantis... ($i/60)"
        sleep 5
      done
      echo "Atlantis nao respondeu em 5 minutos. Veja: make logs" >&2
      exit 1
    EOT
  }
}
