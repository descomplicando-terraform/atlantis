variable "region" {
  description = "Regiao da AWS."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Tipo da instancia."
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Nome do key pair para acesso SSH. Vazio = sem SSH."
  type        = string
  default     = null
}

variable "ssm_parameter" {
  description = "Nome do parametro no SSM com o documento de configuracao (o que 'make secrets' envia)."
  type        = string
  default     = "/atlantis/prod"
}

variable "cidr_liberado" {
  description = "CIDR com acesso as portas do Atlantis e do SSH. Em producao, restrinja."
  type        = string
  default     = "0.0.0.0/0"
}

variable "atlantis_port" {
  description = "Porta em que o Atlantis escuta. Abre o security group e vai para a instancia pelo user_data."
  type        = number
  default     = 4141
}

variable "politica_execucao" {
  description = <<-EOT
    Policy que da ao Atlantis poder para rodar o Terraform.

    AdministratorAccess porque o codigo dos repositorios cria de tudo,
    inclusive IAM -- que PowerUserAccess nao cobre.
  EOT
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}
