<#
.SYNOPSIS
    OpenShift Application Discovery & Assessment Collector (Windows / PowerShell)
.DESCRIPTION
    Coleta dados brutos do cluster OpenShift via `oc`, sanitiza Secrets (sem .data/.stringData)
    e compacta o resultado em .zip. Não requer `jq` nem `oc` no PATH.
.PARAMETER OcPath
    Caminho completo para o executável oc.exe (opcional).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\01-collect-cluster-raw.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\01-collect-cluster-raw.ps1 -OcPath "C:\tools\oc.exe"
#>
param(
    [string]$OcPath = ""
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Resolve-OcBinary {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $ExplicitPath = $ExplicitPath.Trim().Trim('"')
        if (Test-Path -LiteralPath $ExplicitPath -PathType Container) {
            $ExplicitPath = Join-Path $ExplicitPath "oc.exe"
        }
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }
        Write-Host "ERRO: oc.exe não encontrado em '$ExplicitPath'." -ForegroundColor Red
        exit 1
    }

    $cmd = Get-Command "oc" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        (Join-Path $PSScriptRoot "oc.exe"),
        (Join-Path (Get-Location).Path "oc.exe"),
        (Join-Path (Get-Location).Path "oc\oc.exe"),
        (Join-Path $env:USERPROFILE "Downloads\oc.exe"),
        (Join-Path $env:USERPROFILE "Downloads\oc\oc.exe"),
        "C:\oc\oc.exe",
        "C:\tools\oc.exe"
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    Write-Host "AVISO: 'oc.exe' não foi encontrado no PATH nem nos locais padrão." -ForegroundColor Yellow
    $inputPath = Read-Host "Informe o caminho para o oc.exe ou para a pasta dele (ex: C:\tools\oc.exe)"
    $inputPath = $inputPath.Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($inputPath) -and (Test-Path -LiteralPath $inputPath -PathType Container)) {
        $inputPath = Join-Path $inputPath "oc.exe"
    }

    if ([string]::IsNullOrWhiteSpace($inputPath) -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        Write-Host "ERRO: Caminho inválido para oc.exe: '$inputPath'" -ForegroundColor Red
        exit 1
    }

    return (Resolve-Path -LiteralPath $inputPath).Path
}

$OcExe = Resolve-OcBinary -ExplicitPath $OcPath
Write-Host "Usando oc: $OcExe"

Write-Host "Verificando conexão com o cluster OpenShift..."
$UserName = (& $OcExe whoami 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($UserName)) {
    Write-Host "ERRO: Você não está autenticado no cluster. Execute '$OcExe login ...' primeiro." -ForegroundColor Red
    exit 1
}

$ApiServer = (& $OcExe whoami --show-server 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($ApiServer)) { $ApiServer = "unknown" }

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseDir = (Get-Location).Path
$OutputRoot = Join-Path $BaseDir "output"
$OutDir = Join-Path $OutputRoot "assessment-$Timestamp"
$RawDir = Join-Path $OutDir "raw"
New-Item -ItemType Directory -Path $RawDir -Force | Out-Null

Write-Host "Conectado como: $UserName"
Write-Host "API Server:     $ApiServer"
Write-Host "Salvando dados em: $OutDir"

# Salva metadados da coleta
$OcVersionRaw = (& $OcExe version -o json 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($OcVersionRaw)) {
    $OcVersionRaw = ((& $OcExe version 2>$null | Out-String) -replace "`r?`n", " ").Trim()
} else {
    try {
        $OcVersionRaw = ($OcVersionRaw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10)
    } catch {
        $OcVersionRaw = ($OcVersionRaw -replace "`r?`n", " ").Trim()
    }
}

$MetadataContent = @"
timestamp=$Timestamp
user=$UserName
api_server=$ApiServer
oc_version=$OcVersionRaw
"@
[System.IO.File]::WriteAllText((Join-Path $OutDir "metadata.txt"), $MetadataContent, $Utf8NoBom)

function Collect-Resource {
    param(
        [string]$Resource,
        [string]$Filename,
        [string]$Scope = "all"
    )

    Write-Host "  -> Coletando $Resource..."
    $JsonPath = Join-Path $RawDir "$Filename.json"
    $ErrPath = Join-Path $RawDir "$Filename.err"

    $argsList = @("get", $Resource)
    if ($Scope -ne "cluster") {
        $argsList += "-A"
    }
    $argsList += @("-o", "json")

    $proc = Start-Process -FilePath $OcExe `
        -ArgumentList $argsList `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $JsonPath `
        -RedirectStandardError $ErrPath

    if ($proc.ExitCode -ne 0) {
        Write-Host "     [AVISO] Não foi possível coletar $Resource (ver $Filename.err)" -ForegroundColor Yellow
    } else {
        if (Test-Path -LiteralPath $ErrPath) {
            Remove-Item -LiteralPath $ErrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "=== 1. Infraestrutura e Cluster ==="
Collect-Resource "nodes" "nodes" "cluster"
Collect-Resource "clusterversion" "clusterversion" "cluster"
Collect-Resource "infrastructures.config.openshift.io" "infrastructure" "cluster"
Collect-Resource "networks.config.openshift.io" "network_config" "cluster"
Collect-Resource "ingresses.config.openshift.io" "ingress_config" "cluster"
Collect-Resource "storageclasses" "storageclasses" "cluster"
Collect-Resource "persistentvolumes" "persistentvolumes" "cluster"
Collect-Resource "namespaces" "namespaces" "cluster"

Write-Host ""
Write-Host "=== 2. Workloads ==="
Collect-Resource "deployments" "deployments" "all"
Collect-Resource "deploymentconfigs" "deploymentconfigs" "all"
Collect-Resource "statefulsets" "statefulsets" "all"
Collect-Resource "daemonsets" "daemonsets" "all"
Collect-Resource "cronjobs" "cronjobs" "all"
Collect-Resource "jobs" "jobs" "all"
Collect-Resource "pods" "pods" "all"
Collect-Resource "horizontalpodautoscalers" "hpas" "all"
Collect-Resource "poddisruptionbudgets" "pdbs" "all"

Write-Host ""
Write-Host "=== 3. Rede e Exposição ==="
Collect-Resource "services" "services" "all"
Collect-Resource "routes" "routes" "all"
Collect-Resource "ingresses" "ingresses" "all"
Collect-Resource "networkpolicies" "networkpolicies" "all"
Collect-Resource "egressfirewalls" "egressfirewalls" "all"
Collect-Resource "egressnetworkpolicies" "egressnetworkpolicies" "all"

Write-Host ""
Write-Host "=== 4. Storage, Quotas e Configuração ==="
Collect-Resource "persistentvolumeclaims" "pvcs" "all"
Collect-Resource "resourcequotas" "resourcequotas" "all"
Collect-Resource "limitranges" "limitranges" "all"
Collect-Resource "serviceaccounts" "serviceaccounts" "all"
Collect-Resource "configmaps" "configmaps" "all"

# Secrets: NUNCA salvar .data ou .stringData, apenas metadados e chaves
Write-Host "  -> Coletando secrets (somente metadados e nomes das chaves, sem valores)..."
$SecretsTmpJson = Join-Path $RawDir "_secrets_tmp.json"
$SecretsErr = Join-Path $RawDir "secrets.err"
$SecretsOutJson = Join-Path $RawDir "secrets_metadata.json"

$procSec = Start-Process -FilePath $OcExe `
    -ArgumentList @("get", "secrets", "-A", "-o", "json") `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $SecretsTmpJson `
    -RedirectStandardError $SecretsErr

if ($procSec.ExitCode -eq 0 -and (Test-Path -LiteralPath $SecretsTmpJson)) {
    try {
        $secObj = [System.IO.File]::ReadAllText($SecretsTmpJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $sanitizedItems = @()
        foreach ($item in ($secObj.items | ForEach-Object { $_ })) {
            $annotations = @{}
            if ($item.metadata.annotations) {
                foreach ($prop in $item.metadata.annotations.PSObject.Properties) {
                    if ($prop.Name -ne "kubectl.kubernetes.io/last-applied-configuration") {
                        $annotations[$prop.Name] = $prop.Value
                    }
                }
            }
            $keys = @()
            if ($item.data) {
                $keys = @($item.data.PSObject.Properties | ForEach-Object { $_.Name })
            }
            $sanitizedItems += [ordered]@{
                metadata = [ordered]@{
                    name        = $item.metadata.name
                    namespace   = $item.metadata.namespace
                    labels      = $item.metadata.labels
                    annotations = $annotations
                }
                type = $item.type
                keys = $keys
            }
        }
        $sanitizedPayload = [ordered]@{
            apiVersion = $secObj.apiVersion
            kind       = $secObj.kind
            items      = $sanitizedItems
        }
        $jsonOut = $sanitizedPayload | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($SecretsOutJson, $jsonOut, $Utf8NoBom)
        Remove-Item -LiteralPath $SecretsErr -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "     [AVISO] Erro ao sanitizar secrets: $_" -ForegroundColor Yellow
    } finally {
        Remove-Item -LiteralPath $SecretsTmpJson -Force -ErrorAction SilentlyContinue
    }
} else {
    Remove-Item -LiteralPath $SecretsTmpJson -Force -ErrorAction SilentlyContinue
    Write-Host "     [AVISO] Não foi possível coletar secrets (ver secrets.err)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 5. Operators, Builds e GitOps (se disponíveis) ==="
Collect-Resource "subscriptions.operators.coreos.com" "olm_subscriptions" "all"
Collect-Resource "clusterserviceversions.operators.coreos.com" "olm_csvs" "all"
Collect-Resource "buildconfigs" "buildconfigs" "all"
Collect-Resource "imagestreams" "imagestreams" "all"
Collect-Resource "applications.argoproj.io" "argocd_applications" "all"

Write-Host ""
Write-Host "=== 6. Compactação dos dados ==="
$ArchiveFile = Join-Path $OutputRoot "assessment-$Timestamp.zip"
if (Test-Path -LiteralPath $ArchiveFile) {
    Remove-Item -LiteralPath $ArchiveFile -Force
}

Compress-Archive -Path $OutDir -DestinationPath $ArchiveFile -CompressionLevel Optimal -Force

$ArchiveSizeMB = [math]::Round(((Get-Item -LiteralPath $ArchiveFile).Length / 1MB), 2)
Write-Host ""
Write-Host "Coleta concluída com sucesso!" -ForegroundColor Green
Write-Host "Arquivo compactado gerado: $ArchiveFile ($ArchiveSizeMB MB)"
Write-Host "Envie este arquivo para análise."
Write-Host ""
Write-Host "Próximo passo (após descompactar): gerar o mapa e relatórios com:"
Write-Host "  python3 02-generate-assessment-map.py $OutDir"

