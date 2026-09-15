# Interface unica da aula. Cada alvo e um comando so, para ler em voz alta.
SHELL := /bin/bash

# Nome do parametro no SSM que guarda o documento inteiro.
SSM_PARAMETER ?= /atlantis/prod

.PHONY: help ami secrets up down url logs clean

help: ## Lista os alvos
	@grep -E '^[a-z]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

## ---------------------------------------------------------------- 1. imagem

ami: ## Constroi a AMI com Packer + Ansible
	cd packer && packer init . && packer build .

## --------------------------------------------------------- 2. configuracao
# Um parametro so, SecureString, montado a partir de dois arquivos:
#
#   config/atlantis.json  flags do servidor -- cada chave vira uma variavel de
#                         ambiente na instancia, e o Atlantis le todas
#   config/repos.yaml     politica sobre os repositorios -- entra no documento
#                         como a chave ATLANTIS_REPO_CONFIG; na instancia vira
#                         um arquivo, e a variavel aponta para ele
#
# Fica fora do Terraform de proposito: valor gravado por Terraform vira texto
# plano no arquivo de estado.

DOC := config/.documento.json

secrets: ## Envia config/atlantis.json + config/repos.yaml para o SSM
	python3 -c 'import json, yaml; \
		doc = json.load(open("config/atlantis.json")); \
		doc["ATLANTIS_REPO_CONFIG"] = yaml.safe_load(open("config/repos.yaml")); \
		json.dump(doc, open("$(DOC)", "w"))'
	aws ssm put-parameter --overwrite --type SecureString \
		--name $(SSM_PARAMETER) --value file://$(DOC)
	rm -f $(DOC)
	@echo "Enviado. Na instancia: sudo systemctl restart atlantis-env atlantis"

## ------------------------------------------------------------ 3. instancia

up: ## Sobe a EC2 com Terraform
	cd terraform && terraform init && terraform apply -var ssm_parameter=$(SSM_PARAMETER)

down: ## Destroi a EC2
	cd terraform && terraform init && terraform destroy -var ssm_parameter=$(SSM_PARAMETER)

url: ## Mostra a URL do Atlantis e do webhook
	cd terraform && terraform output

logs: ## Acompanha o boot do Atlantis pela instancia
	ssh ubuntu@$$(cd terraform && terraform output -raw ip) \
		'sudo journalctl -u atlantis-env -u atlantis -f'

clean: ## Apaga o parametro do SSM
	aws ssm delete-parameter --name $(SSM_PARAMETER)
