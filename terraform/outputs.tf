output "ip" {
  description = "IP publico fixo (Elastic IP). Nao muda quando a instancia e recriada."
  value       = aws_eip.atlantis.public_ip
}

output "url" {
  description = "Interface web do Atlantis."
  value       = "http://${aws_eip.atlantis.public_ip}:${var.atlantis_port}"
}

output "webhook_url" {
  description = "URL para cadastrar no webhook do GitHub."
  value       = "http://${aws_eip.atlantis.public_ip}:${var.atlantis_port}/events"
}

output "iam_role_name" {
  description = "Nome da role da instancia (o modulo gera com prefixo 'atlantis-')."
  value       = module.atlantis.iam_role_name
}

output "iam_role_arn" {
  description = "ARN da role da instancia. E este o principal que uma role de execucao precisa confiar, quando a aula 3 trocar o admin direto por assume role."
  value       = module.atlantis.iam_role_arn
}
