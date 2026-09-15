data "aws_caller_identity" "atual" {}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    sid    = "LerConfiguracaoDoAtlantisNoSSM"
    effect = "Allow"

    actions = ["ssm:GetParameter"]

    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.atual.account_id}:parameter${var.ssm_parameter}"
    ]
  }

  statement {
    sid    = "DecriptarSecureStringViaSSM"
    effect = "Allow"

    actions = ["kms:Decrypt"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ssm_read" {
  name        = "atlantis-ssm-read"
  description = "Leitura da configuracao do Atlantis no SSM Parameter Store"
  policy      = data.aws_iam_policy_document.ssm_read.json
}

resource "aws_iam_role_policy_attachment" "execucao" {
  role       = module.atlantis.iam_role_name
  policy_arn = var.politica_execucao
}
