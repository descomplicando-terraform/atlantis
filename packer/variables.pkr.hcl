variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Regiao onde a AMI sera construida."
}

variable "instance_type" {
  type        = string
  default     = "t3.small"
  description = "Tipo da instancia usada apenas durante o build."
}

variable "ami_prefix" {
  type        = string
  default     = "atlantis"
  description = "Prefixo do nome da AMI. O nome final vira <prefixo>-<versao>-<timestamp>."
}

variable "atlantis_version" {
  type        = string
  default     = "v0.47.1"
  description = "Versao do Atlantis instalada na imagem."
}

variable "terraform_version" {
  type        = string
  default     = "1.16.2"
  description = "Versao do Terraform instalada na imagem."
}

variable "atlantis_port" {
  type        = number
  default     = 4141
  description = "Porta em que o Atlantis escuta."
}

variable "atlantis_ssm_parameter" {
  type        = string
  default     = "/atlantis/prod"
  description = "Nome default do parametro no SSM com a configuracao. O user_data do Terraform pode sobrescrever."
}

variable "volume_size" {
  type        = number
  default     = 20
  description = "Tamanho do disco raiz em GB."
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC para o build. Vazio = VPC default da regiao."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet publica para o build. Vazio = Packer escolhe uma."
}
