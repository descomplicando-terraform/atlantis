# Atlantis: AMI com Packer + Ansible, configuração no SSM, EC2 com Terraform

Na [aula 1](../aula1/run.md) o Atlantis subia com um `docker run` gigante e os
segredos no meio do comando: token do GitHub, webhook secret e chave da AWS em
texto plano, no shell, no histórico e no repositório.

Aqui a gente separa as quatro coisas que estavam misturadas:

| | onde vive agora | ferramenta |
|---|---|---|
| **Software** — binário do Atlantis, Terraform, AWS CLI, units do systemd | dentro da AMI | Packer + Ansible |
| **Configuração e segredos** | SSM Parameter Store | `make secrets` |
| **Infraestrutura** — EC2, security group, IAM | código versionado | Terraform |
| **Credenciais da AWS** | não existem — instance profile | — |

A AMI é **genérica**: a mesma imagem serve dev, staging e produção. O que muda
é qual parâmetro do SSM ela lê no boot.

---

## Os comandos da aula

```bash
make ami        # 1. constrói a AMI        (Packer + Ansible)
make secrets    # 2. envia a configuração  (SSM Parameter Store)
make up         # 3. sobe a EC2            (Terraform)
make url        # 4. mostra o endereço
```

E `make down` derruba tudo no fim.

Repare que **só o primeiro reconstrói imagem**. Mudou uma flag ou uma regra
de repositório? É `make secrets` mais um restart — a AMI não muda e a
instância não é recriada.

---

## Por que SSM Parameter Store e não Secrets Manager

| | **SSM Parameter Store** (Standard) | Secrets Manager |
|---|---|---|
| Armazenamento | **US$ 0,00** (até 10.000 parâmetros) | US$ 0,40 / segredo / mês |
| Chamadas de API | **US$ 0,00** | US$ 0,05 / 10.000 |
| Criptografia | SecureString com a chave `aws/ssm` (grátis) | KMS |
| Rotação automática | não | sim |

É **um parâmetro só**, SecureString, com toda a configuração dentro. O
Secrets Manager custaria US$ 0,40/mês para guardar o mesmo documento; o
Atlantis não precisa de rotação automática, e a leitura é uma chamada só
(`GetParameter`). **Custo zero.**

> O limite do tier Standard é 4 KB por parâmetro. O documento da aula tem
> menos de 1 KB; com uma chave privada de GitHub App dentro fica em ~3 KB. Se
> passar, o tier Advanced (8 KB) custa US$ 0,05/mês — ainda longe do Secrets
> Manager. Para trocar de serviço um dia, só muda o script de boot da AMI.

---

## Estrutura

```
aula2/
├── Makefile                  # a interface: ami, secrets, up, down, url, logs
├── packer/
│   ├── atlantis.pkr.hcl      # source amazon-ebs + provisioner ansible
│   ├── variables.pkr.hcl
│   └── cleanup.sh            # limpa rastros do build antes do snapshot
├── config/
│   ├── atlantis.json.example # flags do servidor (copie para atlantis.json)
│   └── repos.yaml            # política sobre os repositórios
├── ansible/
│   ├── playbook.yml
│   └── roles/atlantis/
│       ├── defaults/main.yml     # versões e caminhos
│       ├── templates/            # .j2 — units, config e script de boot
│       ├── handlers/main.yml     # daemon-reload
│       └── tasks/
│           ├── main.yml          # só a ordem dos arquivos abaixo
│           ├── base.yml          # pacotes e AWS CLI v2
│           ├── terraform.yml     # binário do Terraform
│           ├── usuario.yml       # usuário de sistema e diretórios
│           ├── instalacao.yml    # binário do Atlantis
│           ├── configuracao.yml  # atlantis.conf e script de boot
│           └── servico.yml       # units do systemd
└── terraform/
    ├── main.tf               # a AMI e o módulo pronto da EC2
    ├── iam.tf                # a permissão de leitura do SSM
    ├── variables.tf
    └── outputs.tf
```

---

## Como funciona

### No build — Packer chama o Ansible

1. O Packer sobe uma Ubuntu 24.04 temporária.
2. O Ansible instala tudo direto na máquina: AWS CLI v2, o binário do Terraform
   e o binário do Atlantis — **nada é baixado no boot**.
3. Cria o usuário de sistema `atlantis`, os diretórios, a configuração e duas
   units do systemd.
4. `cleanup.sh` zera logs, chaves de host SSH e `machine-id`.
5. Snapshot → AMI.

#### Os módulos do Ansible que aparecem aqui

É **uma role só**. O `tasks/main.yml` não executa nada: só declara a ordem dos
seis arquivos, cada um cuidando de um assunto.

| Módulo | Arquivo | Para quê |
|---|---|---|
| `apt` | `base.yml` | pacotes do sistema |
| `get_url` | `terraform.yml`, `instalacao.yml` | baixar os binários, **conferindo o checksum** |
| `unarchive` | `terraform.yml`, `instalacao.yml` | extrair só o binário de dentro do zip |
| `group` / `user` | `usuario.yml` | usuário de sistema sem shell |
| `file` | `usuario.yml`, `servico.yml` | diretórios com dono e permissão certos |
| `template` | `configuracao.yml`, `servico.yml` | configs e units — passam pelo Jinja |
| `systemd_service` | `servico.yml` | habilitar no boot |
| `assert` | `instalacao.yml` | falhar o build se a versão vier errada |
| `command` + `register` | vários | conferir as versões instaladas |
| handler + `notify` | `servico.yml` | `daemon-reload` uma vez só, no fim |

Dois contrastes que rendem discussão:

**`get_url` com `checksum`** — aponta para o `checksums.txt` da própria
release. O Ansible baixa esse arquivo, acha a linha do nosso zip e compara
sozinho. Sem isso, um download corrompido entraria na imagem calado.

**`template` com `validate`** — o Ansible roda `bash -n` no arquivo gerado
*antes* de instalar. Se o Jinja produzir shell inválido, o build para ali, e
não no boot da instância.

**Nenhum segredo entra na imagem.** A AMI sabe *como* buscar a configuração,
não *qual* é ela.

### No boot da instância

```
atlantis-env.service (oneshot)           atlantis.service
  │                                        │
  ├─ lê atlantis.conf (parâmetro, região)  │ espera o oneshot terminar
  ├─ aws ssm get-parameter (um documento)  │
  └─ escreve atlantis.env ─────────────────┤ EnvironmentFile=atlantis.env
       (0600, root)                        │ EnvironmentFile=atlantis.conf
                                           ▼
                                  /usr/local/bin/atlantis server
```

O parâmetro é **um documento JSON**, e o script de boot **não interpreta
nada**: para cada chave, escreve uma linha `CHAVE="valor"`. A chave é o nome
da variável, sem conversão nenhuma:

```json
{"ATLANTIS_GH_TOKEN": "ghp_...", "ATLANTIS_LOG_LEVEL": "debug"}
```
```
ATLANTIS_GH_TOKEN="ghp_..."
ATLANTIS_LOG_LEVEL="debug"
```

Um valor que seja objeto ou lista (o `ATLANTIS_REPO_CONFIG`, vindo do
`repos.yaml`) não cabe bem numa variável de ambiente. O script grava esse
valor num arquivo próprio — `/etc/atlantis/atlantis_repo_config.json` — e a
variável recebe o caminho:

```
ATLANTIS_REPO_CONFIG="/etc/atlantis/atlantis_repo_config.json"
```

É exatamente o que o Atlantis espera: `ATLANTIS_REPO_CONFIG` é a forma em
variável da flag `--repo-config`, que recebe um arquivo. Um valor com quebra
de linha (o PEM de um GitHub App em `ATLANTIS_GH_APP_KEY`) vai entre aspas, e
o systemd lê multilinha sem problema.

Isso funciona porque o Atlantis aceita **toda** flag como variável de
ambiente. A única regra do script é a de tipo: valor simples vira variável,
valor composto vira arquivo.

#### Dois arquivos de origem, um parâmetro

O `make secrets` monta o documento a partir de dois arquivos, porque são duas
camadas de configuração diferentes:

| Arquivo | Camada | Quem decide |
|---|---|---|
| `config/atlantis.json` | flags do servidor — credenciais, allowlist, log | quem opera o Atlantis |
| `config/repos.yaml` | política sobre os repositórios — `apply_requirements`, overrides permitidos | quem opera, sobre os times |

O `repos.yaml` entra no documento como a chave `ATLANTIS_REPO_CONFIG`.
Ele poderia ser escrito direto no JSON, mas aí a distinção entre "flag do
servidor" e "política sobre os repos" sumiria — e ela é a parte que vale
ensinar.

#### Dois arquivos, uma regra de precedência

A unit carrega dois `EnvironmentFile`, nesta ordem. Se a mesma variável estiver
nos dois, **vale o último**:

| Arquivo | Quem escreve | O que tem |
|---|---|---|
| `atlantis.env` | script de boot, a partir do SSM | segredos e configuração do Atlantis |
| `atlantis.conf` | `user_data` do Terraform | o que a infra sabe: nome do parâmetro, região, porta, URL pública |

O `atlantis.conf` vence porque o Terraform é a fonte de verdade para o que ele
mesmo criou: abriu o security group naquela porta, alocou aquele IP. O SSM
não tem como saber disso.

#### O que é imagem e o que é configuração

A unit roda `atlantis server` sem uma flag sequer. Nenhuma opção do Atlantis
exige AMI nova.

| | Muda com |
|---|---|
| Versão do Atlantis e do Terraform | `make ami` |
| Usuário, diretórios, sandbox do systemd | `make ami` |
| Porta, região, URL | `make up` (via `user_data`) |
| Credenciais, allowlist, log, repos config, qualquer flag | `make secrets` + restart |

### O Terraform

São dois arquivos curtos.

**`main.tf`** — o que sobe a máquina:

- `data "aws_ami"` — acha a AMI mais recente que o Packer construiu
- `data "aws_vpc"` / `data "aws_subnets"` — a VPC default e suas subnets
- `aws_eip` + `aws_eip_association` — IP fixo, criado antes da instância
- `module "atlantis"` — [terraform-aws-modules/ec2-instance](https://registry.terraform.io/modules/terraform-aws-modules/ec2-instance/aws)
- `terraform_data.espera_atlantis` — segura o `apply` até o `/healthz` responder

Esse módulo entrega **instância, security group, IAM role e instance profile**
de uma vez. Sem VPC nova: ele usa a VPC default da conta.

A VPC default tem uma subnet por zona de disponibilidade, e o módulo precisa de
uma só — daí o `data "aws_subnets"`. O `sort()` na hora de escolher não é
detalhe: a AWS não garante a ordem da lista, e uma subnet diferente a cada
`plan` recriaria a instância do nada.

**`iam.tf`** — a permissão que a instância recebe:

- `data "aws_caller_identity"` — o ID da conta, para montar o ARN
- `data "aws_iam_policy_document"` — a policy, em HCL
- `resource "aws_iam_policy"` — a policy criada de fato

O `aws_iam_policy_document` é o jeito idiomático de escrever policy em
Terraform. Dá para montar o mesmo JSON com `jsonencode`, mas aí é uma string
opaca: o Terraform não valida a estrutura, o diff sai ilegível e errar o nome
de um campo só aparece quando a AWS recusa no `apply`. Com o data source, o
`plan` já reclama.

Dois detalhes do módulo que valem o comentário em aula:

```hcl
create_iam_instance_profile = true
iam_role_policies = { ssm_read = aws_iam_policy.ssm_read.arn }
```
O módulo cria a role e o instance profile; a gente só anexa as permissões do
`iam.tf`. Sem isso seria uma role, uma policy de trust, um instance profile e
uma associação escritos à mão.

```hcl
user_data = <<-EOT
  cat > /etc/atlantis/atlantis.conf <<CONF
  SSM_PARAMETER=${var.ssm_parameter}
  AWS_REGION=${var.region}
  ATLANTIS_PORT=${var.atlantis_port}
  ATLANTIS_ATLANTIS_URL=http://${aws_eip.atlantis.public_ip}:${var.atlantis_port}
  CONF
EOT
```
É aqui que a AMI genérica recebe o que só a infra sabe. Mesma imagem,
`make up SSM_PARAMETER=/atlantis/staging`, outra configuração.

O Elastic IP existe por causa dessa linha da URL: o Terraform precisa
conhecer o endereço **antes** de criar a instância, e o IP automático só existe
depois. Efeito colateral bem-vindo: o webhook do GitHub para de quebrar toda
vez que a instância é recriada. Custa o mesmo que o IP automático.

### Credenciais da AWS

Repare que **`AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` não aparecem em
lugar nenhum** — nem no SSM, nem no Terraform. O processo herda o instance
profile pelo IMDS e usa credenciais temporárias que a AWS rotaciona sozinha.
Foi o segredo mais perigoso da aula 1 e ele simplesmente deixou de existir.

A role da instância recebe duas permissões:

- `aws_iam_policy.ssm_read` — leitura de **um** parâmetro do SSM, e só dele
- `var.politica_execucao` — `AdministratorAccess`, para o Terraform trabalhar

A segunda é a parte grosseira do desenho, e está comentada como tal no
`iam.tf`: quem abre um pull request decide o que o Terraform executa com esse
poder todo. **O refinamento é a aula 3**: a instância fica só com
`sts:AssumeRole` e assume uma role por ambiente, com permissão restrita. Isso
muda também o `provider` nos repositórios que o Atlantis administra, então é
assunto próprio.

> É `AdministratorAccess` porque o código dos repositórios cria de tudo,
> inclusive IAM — que `PowerUserAccess` não cobre. Para restringir num
> ambiente real, `make up` aceita
> `-var politica_execucao=<arn da sua policy>`.

### Por que os segredos não estão no Terraform

Um `aws_ssm_parameter` com o token dentro gravaria o valor **em texto plano no
arquivo de estado** — o mesmo problema da aula 1, só que em outro arquivo. Por
isso `make secrets` usa a AWS CLI direto, e o Terraform só cria infraestrutura.

---

## Passo a passo

### Pré-requisitos

```bash
packer version
ansible --version
terraform version
aws sts get-caller-identity
```

### 1. Construir a AMI

```bash
make ami
```

Para mudar a versão do Atlantis: `cd packer && packer build -var atlantis_version=v0.34.0 .`

### 2. Gravar a configuração

```bash
cp config/atlantis.json.example config/atlantis.json
# edite: usuário, token, webhook secret, allowlist
make secrets
```

O `config/atlantis.json` tem o token do GitHub e por isso está no
`.gitignore` — só o `.example` é versionado. Qualquer flag do Atlantis pode
ser adicionada ali como mais uma chave; a política sobre os repositórios fica
em [`config/repos.yaml`](config/repos.yaml) e o `make secrets` junta os dois.

### 3. Subir a EC2

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # opcional
make up
make url
```

O `make up` só devolve o prompt quando o Atlantis **responde** — não quando a
EC2 existe. É o `terraform_data.espera_atlantis` no fim do `main.tf`: um
`local-exec` que consulta `/healthz` a cada 5 segundos, por até 5 minutos.
Se estourar, o `apply` falha com a instância de pé; `make logs` mostra o que
travou, e o próximo `make up` só refaz a espera.

Roda na sua máquina, então ela precisa alcançar a porta do Atlantis — com
`cidr_liberado` restrito, use o mesmo IP.

### 4. Configurar o webhook no GitHub

No repositório → Settings → Webhooks → Add webhook:

- **Payload URL**: a saída de `make url`
- **Content type**: `application/json`
- **Secret**: o mesmo valor de `GH_WEBHOOK_SECRET`
- **Events**: Pull requests, Issue comments, Pushes

### 5. No fim da aula

```bash
make down     # destrói a EC2
make clean    # apaga os parâmetros do SSM
```

---

## Operação

```bash
make logs     # acompanha o boot pela instância

# mudou config/atlantis.json ou config/repos.yaml? envia e reinicia, sem recriar nada
make secrets
sudo systemctl restart atlantis-env.service atlantis.service

# a mesma AMI em outro ambiente
make up SSM_PARAMETER=/atlantis/staging
```

### Quando não sobe

Dois lugares para olhar, e o `make logs` mostra os dois:

**`atlantis-env.service`** falha se não consegue montar o `atlantis.env`:

| Mensagem | Causa |
|---|---|
| `falha ao ler /atlantis/prod` | `make secrets` não rodou, ou o nome do parâmetro é outro; ou o instance profile aponta para outro |
| `o valor de /atlantis/prod nao e um objeto JSON` | o documento chegou quebrado — confira o `config/atlantis.json` |
| Atlantis diz que uma flag `must be set`, mas a chave existe | chave em minúsculas — tem de ser exatamente `ATLANTIS_...` |
| `sem AWS_REGION ... e sem resposta do IMDS` | `user_data` não rodou e IMDSv2 está desabilitado |

**`atlantis.service`** falha se a configuração está incompleta — e a
mensagem é do próprio Atlantis, que valida o que recebeu:

| Mensagem | Causa |
|---|---|
| `--gh-user/--gh-token or ... must be set` | `ATLANTIS_GH_TOKEN` não está no SSM |
| `--repo-allowlist must be set` | `ATLANTIS_REPO_ALLOWLIST` não foi gravado |
| `unable to verify checksums signature: openpgp: key expired` | versão do Atlantis com a chave GPG vencida; veja abaixo |

---

## As versões do Terraform

A imagem já traz o Terraform instalado pelo Ansible, e é ele que o Atlantis usa
quando o repositório não pede versão específica. Quando pede, o Atlantis baixa
a versão certa sob demanda e guarda em `/var/lib/atlantis/bin`.

Para isso, a unit do systemd precisa manter `/var/lib/atlantis` gravável — é o
que o `ReadWritePaths` garante, já que `ProtectSystem=full` tranca o resto.

### O erro da chave GPG expirada

O Atlantis verifica a assinatura dos checksums da HashiCorp antes de instalar o
binário baixado, e usa uma cópia da chave pública **embutida no próprio
binário**. Versões antigas trazem uma cópia que já venceu:

```
error downloading terraform version 1.16.0:
unable to verify checksums signature: openpgp: key expired
```

Não é problema de rede nem de permissão, e tentar de novo não resolve. A chave
é a mesma (`34365D9472D7468F`, HashiCorp Security); o que mudou foi a validade:

| Atlantis | validade da chave embutida |
|---|---|
| v0.35.0 | venceu em **18/04/2026** |
| v0.47.1 | vale até **01/03/2030** |

Por isso a imagem usa **v0.47.1**. Se o erro voltar um dia, é o mesmo remédio:
subir `atlantis_version` e reconstruir a AMI.

> Dá para conferir isso em qualquer release, sem instalar nada — a chave está
> em texto no binário:
> ```bash
> grep -a -A30 "BEGIN PGP PUBLIC KEY BLOCK" atlantis | gpg --show-keys
> ```

## Notas de segurança

- O `atlantis.env` é `0600 root:root` e é **recriado a cada boot** — não
  sobrevive no snapshot da AMI. O systemd o lê como root antes de trocar para
  o usuário `atlantis`, então nem o processo do Atlantis consegue abri-lo.
- IMDSv2 obrigatório na AMI e na instância — fecha o vetor de SSRF que permite
  roubar credenciais do instance profile.
- `cidr_liberado` é `0.0.0.0/0` por padrão para a aula funcionar. Em produção,
  restrinja aos [IPs de webhook do GitHub](https://api.github.com/meta) e
  coloque um ALB com TLS na frente.
- O Atlantis roda como usuário de sistema sem shell, não como root, e a unit
  do systemd tem `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full` e
  `ProtectHome` — ele executa código vindo de pull request, então vale limitar
  o que alcança na máquina.
- O `config/repos.yaml` vai com `apply_requirements: []` para a demo funcionar
  — o GitHub não deixa ninguém aprovar o próprio pull request, e com um
  repositório só isso travaria o `atlantis apply`. **Em produção é o
  contrário**: é ali que se exige `approved` e `mergeable` antes de aplicar
  qualquer coisa. O arquivo já vem com as opções comentadas.

> **Se você rodou a aula 1**: revogue o token do GitHub, o webhook secret e a
> access key que ficaram em `aula1/run.md`. Eles estão em texto plano no
> repositório e devem ser considerados comprometidos.
