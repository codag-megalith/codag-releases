$ErrorActionPreference = "Stop"

$Repo = "codag-megalith/codag-releases"
$Binary = "codag.exe"
$TaskName = "Codag Agent Cost Proxy"
$InstallDir = if ($env:CODAG_INSTALL_DIR) { $env:CODAG_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Codag\bin" }

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

$Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()) {
    "x64" { "amd64" }
    "arm64" { "arm64" }
    default { Fail "Unsupported Windows architecture." }
}

$Headers = @{ Accept = "application/vnd.github+json"; "User-Agent" = "codag-installer" }
if ($env:GITHUB_TOKEN) { $Headers.Authorization = "Bearer $($env:GITHUB_TOKEN)" }
$RequestedVersion = if ($env:CODAG_VERSION) { $env:CODAG_VERSION.TrimStart("v") } else { "" }
if ($RequestedVersion -and $RequestedVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    Fail "CODAG_VERSION must be a stable semantic version such as 0.2.2."
}
$ReleaseEndpoint = if ($RequestedVersion) {
    "https://api.github.com/repos/$Repo/releases/tags/v$RequestedVersion"
} else {
    "https://api.github.com/repos/$Repo/releases/latest"
}
$Release = Invoke-RestMethod -Headers $Headers -Uri $ReleaseEndpoint
$Version = $Release.tag_name.TrimStart("v")
$ArchiveName = "codag_windows_$Architecture.zip"
$ArchiveAsset = $Release.assets | Where-Object { $_.name -eq $ArchiveName } | Select-Object -First 1
$ChecksumAsset = $Release.assets | Where-Object { $_.name -eq "checksums.txt" } | Select-Object -First 1
if (-not $ArchiveAsset -or -not $ChecksumAsset) { Fail "The release is missing Windows archive or checksum assets." }

$Temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("codag-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Temporary | Out-Null
try {
    $Archive = Join-Path $Temporary $ArchiveName
    $Checksums = Join-Path $Temporary "checksums.txt"
    Invoke-WebRequest -UseBasicParsing -Uri $ArchiveAsset.browser_download_url -OutFile $Archive
    Invoke-WebRequest -UseBasicParsing -Uri $ChecksumAsset.browser_download_url -OutFile $Checksums

    $ExpectedLine = Get-Content $Checksums | Where-Object { $_ -match "\s$([regex]::Escape($ArchiveName))$" } | Select-Object -First 1
    if (-not $ExpectedLine) { Fail "Checksum for $ArchiveName was not found." }
    $Expected = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { Fail "Checksum verification failed." }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh auth status *>$null
        if ($LASTEXITCODE -ne 0) {
            if ($env:CODAG_REQUIRE_ATTESTATION -eq "1") {
                Fail "GitHub CLI is not authenticated; cannot verify signed build provenance. Run 'gh auth login', then retry."
            }
            Write-Warning "GitHub CLI is not authenticated; skipping signed build-provenance verification. SHA256 checksum verification remains mandatory."
        } else {
            & gh attestation verify $Archive --repo $Repo *>$null
            if ($LASTEXITCODE -ne 0) { Fail "Signed build-provenance verification failed; the downloaded artifact does not match the signed release." }
            Write-Host "Signed build provenance verified."
        }
    } elseif ($env:CODAG_REQUIRE_ATTESTATION -eq "1") {
        Fail "GitHub CLI is required because CODAG_REQUIRE_ATTESTATION=1. Install gh, then retry."
    } else {
        Write-Warning "GitHub CLI was not found; skipping signed build-provenance verification. SHA256 checksum verification remains mandatory."
    }

    Expand-Archive -Path $Archive -DestinationPath $Temporary -Force
    $Source = Join-Path $Temporary $Binary
    if (-not (Test-Path $Source)) { Fail "The verified archive did not contain $Binary." }
    & $Source version | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "The verified binary failed its pre-install health check." }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Installed = Join-Path $InstallDir $Binary
    $Staged = Join-Path $InstallDir ".codag.new.exe"
    $Rollback = Join-Path $InstallDir ".codag.rollback.exe"
    Copy-Item -Force $Source $Staged

    $HadTask = $null -ne (schtasks.exe /Query /TN $TaskName 2>$null)
    if ($HadTask) {
        schtasks.exe /End /TN $TaskName 2>$null | Out-Null
        Start-Sleep -Milliseconds 750
    }
    if (Test-Path $Rollback) { Remove-Item -Force $Rollback }
    if (Test-Path $Installed) { Move-Item -Force $Installed $Rollback }
    try {
        Move-Item -Force $Staged $Installed
        & $Installed version | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "post-install health check failed" }
        if ($HadTask) {
            schtasks.exe /Run /TN $TaskName | Out-Null
            $Healthy = $false
            for ($Attempt = 0; $Attempt -lt 32; $Attempt++) {
                & $Installed status --local *>$null
                if ($LASTEXITCODE -eq 0) { $Healthy = $true; break }
                Start-Sleep -Milliseconds 250
            }
            if (-not $Healthy) { throw "updated service health check failed" }
        }
        if (Test-Path $Rollback) { Remove-Item -Force $Rollback }
    } catch {
        if (Test-Path $Installed) { Remove-Item -Force $Installed }
        if (Test-Path $Rollback) { Move-Item -Force $Rollback $Installed }
        if ($HadTask) { schtasks.exe /Run /TN $TaskName 2>$null | Out-Null }
        throw
    }

    Write-Host "Codag CLI v$Version installed to $Installed"
    Write-Host "Run: $Installed setup"
} finally {
    if (Test-Path $Temporary) { Remove-Item -Recurse -Force $Temporary }
}
