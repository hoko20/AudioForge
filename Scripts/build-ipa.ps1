# One-click GitHub Actions build for WQtool.
# Creates (or reuses) the GitHub repository, pushes the source, dispatches the
# "Build WQtool IPA" workflow, waits for it, then downloads the IPA into dist\.
#
# Usage (usually called by build-ipa.bat):
#   $env:GH_TOKEN = '<PAT with repo + workflow scopes>'
#   .\Scripts\build-ipa.ps1 -Repo 'hoko20/WQtool'
param(
    [string]$Repo = $(if ($env:WQTOOL_REPO) { $env:WQTOOL_REPO } else { 'hoko20/WQtool' }),
    [string]$Token = $env:GH_TOKEN,
    [string]$Branch = 'main',
    [string]$Workflow = 'build-ipa.yml',
    [string]$ArtifactName = 'WQtool-IPA',
    [int]$TimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Info($msg) { Write-Host "[INFO ] $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "[ OK  ] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function StatusCode($err) {
    if ($err.Exception.Response -and $err.Exception.Response.StatusCode) {
        return [int]$err.Exception.Response.StatusCode
    }
    return 0
}

# ---------- prerequisites ----------
foreach ($tool in @('git', 'curl.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool was not found in PATH."
    }
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

if (-not $Token) {
    Write-Host 'GitHub token (PAT with repo + workflow scopes) is required.' -ForegroundColor Yellow
    $secure = Read-Host 'Paste token (input is hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if (-not $Token) { Fail 'No token provided.' }

if (-not $Repo) { $Repo = Read-Host 'Repository (owner/name)' }
if ($Repo -notmatch '^[^/]+/[^/]+$') { Fail "Repo must be owner/name, got: $Repo" }

$headers = @{
    Authorization = "Bearer $Token"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'WQtool-Build'
}

# ---------- account ----------
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers
} catch {
    Fail "GitHub authentication failed (HTTP $(StatusCode $_)). Check the token."
}
Ok "Authenticated as $($me.login)"

# ---------- repository ----------
$repoExists = $false
try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $headers | Out-Null
    $repoExists = $true
} catch {
    if ((StatusCode $_) -ne 404) { Fail "Cannot read repository $Repo (HTTP $(StatusCode $_))." }
}

if (-not $repoExists) {
    $owner, $name = $Repo.Split('/')
    if ($owner -ne $me.login) {
        Fail "Repository $Repo does not exist. Create it first, or use $($me.login)/$name."
    }
    $body = @{
        name        = $name
        private     = $true
        description = 'WQtool - sandbox container access'
        has_issues  = $false
        has_wiki    = $false
        has_projects= $false
        auto_init   = $false
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri 'https://api.github.com/user/repos' -Headers $headers -Body $body | Out-Null
        Ok "Repository $Repo created."
    } catch {
        Fail "Cannot create repository $Repo (HTTP $(StatusCode $_))."
    }
}

# ---------- push source ----------
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    git init -b $Branch | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'git init failed.' }
}
git config user.name  $me.login | Out-Null
git config user.email "$($me.login)@users.noreply.github.com" | Out-Null

git add -A
if (git status --porcelain) {
    git commit -q -m 'WQtool: GitHub Actions build'
    if ($LASTEXITCODE -ne 0) { Fail 'git commit failed.' }
}
Info "Pushing $Branch to $Repo ..."

$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
git -c "http.extraheader=AUTHORIZATION: basic $basic" push --force "https://github.com/$Repo.git" "${Branch}:${Branch}"
if ($LASTEXITCODE -ne 0) {
    Fail 'git push failed. The token needs repo + workflow scopes (workflow scope is required for .github/workflows).'
}
Ok 'Source pushed.'

# ---------- trigger the workflow ----------
$dispatchTarget = $Workflow
try {
    $wfList = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/workflows" -Headers $headers
    $wf = $wfList.workflows | Where-Object { $_.path -eq ".github/workflows/$Workflow" } | Select-Object -First 1
    if ($wf) { $dispatchTarget = [string]$wf.id }
} catch { }
$dispatchUrl = "https://api.github.com/repos/$Repo/actions/workflows/$dispatchTarget/dispatches"
$dispatched = $false
for ($i = 1; $i -le 10; $i++) {
    try {
        Invoke-RestMethod -Method Post -Uri $dispatchUrl -Headers $headers `
            -Body (@{ ref = $Branch } | ConvertTo-Json -Compress) | Out-Null
        $dispatched = $true
        break
    } catch {
        $code = StatusCode $_
        if ($code -eq 404 -or $code -eq 422) {
            Info "Workflow not ready yet (HTTP $code), retry $i/10 ..."
            Start-Sleep -Seconds 6
        } else {
            Fail "Cannot dispatch $Workflow (HTTP $code)."
        }
    }
}
if (-not $dispatched) {
    Fail "Workflow $Workflow was not dispatched. Check that it exists on branch $Branch."
}
Ok 'Workflow dispatched.'

# ---------- wait for the run ----------
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/runs?branch=$Branch&event=workflow_dispatch&per_page=10" -Headers $headers
    $run = $runs.workflow_runs |
        Where-Object { $_.path -like "*$Workflow*" } |
        Sort-Object created_at -Descending |
        Select-Object -First 1
    if ($run) {
        Write-Host "  run $($run.id): $($run.status) / $($run.conclusion)"
        if ($run.status -eq 'completed') { break }
    }
    Start-Sleep -Seconds 10
}
if (-not $run -or $run.status -ne 'completed') {
    Fail "Timed out after $TimeoutMinutes minutes waiting for the build."
}
if ($run.conclusion -ne 'success') {
    Fail "Workflow failed ($($run.conclusion)). Logs: https://github.com/$Repo/actions/runs/$($run.id)"
}
Ok "Build succeeded: https://github.com/$Repo/actions/runs/$($run.id)"

# ---------- download the IPA ----------
$artifacts = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/runs/$($run.id)/artifacts" -Headers $headers
$artifact = $artifacts.artifacts | Where-Object { $_.name -eq $ArtifactName } | Select-Object -First 1
if (-not $artifact) { Fail "Artifact $ArtifactName not found on run $($run.id)." }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "$ArtifactName.zip"
Info 'Downloading artifact ...'
& curl.exe -sSL -H "Authorization: Bearer $Token" -o $zip $artifact.archive_download_url
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip)) { Fail 'Artifact download failed.' }

$unzip = Join-Path $dist 'artifact'
if (Test-Path -LiteralPath $unzip) { Remove-Item -LiteralPath $unzip -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $unzip -Force

$ipa = Get-ChildItem -LiteralPath $unzip -Filter '*.ipa' -Recurse | Select-Object -First 1
if (-not $ipa) { Fail 'No .ipa inside the artifact.' }
$out = Join-Path $dist 'WQtool-adhoc.ipa'
Copy-Item -LiteralPath $ipa.FullName -Destination $out -Force

Ok "IPA ready: $out"
Info 'This IPA is adhoc-signed; use AltStore / SideStore / Sideloadly to install. Keep the App Group entitlement.'
exit 0
