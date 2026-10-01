function Get-FireLauncherDirectory {
    if ($IsWindows) { return Join-Path $env:LOCALAPPDATA 'FIRE/bin' }
    return Join-Path $HOME '.local/bin'
}

function Remove-FireMarkedBlock {
    param([string]$Path, [string]$Start, [string]$End)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $content = [IO.File]::ReadAllText($Path)
    $a = $content.IndexOf($Start, [StringComparison]::Ordinal)
    $b = $content.IndexOf($End, [StringComparison]::Ordinal)
    if ($a -lt 0 -and $b -lt 0) { return }
    if ($a -lt 0 -or $b -lt $a) { throw "Incomplete FIRE block in '$Path'." }
    $after = $b + $End.Length
    if ($after -lt $content.Length -and $content[$after] -eq "`r") { $after++ }
    if ($after -lt $content.Length -and $content[$after] -eq "`n") { $after++ }
    [IO.File]::WriteAllText($Path, $content.Remove($a, $after - $a), [Text.UTF8Encoding]::new($false))
}

function Add-FirePathBlock {
    param([string]$Path, [string]$Line)

    $start = '# >>> FIRE PATH >>>'
    $end = '# <<< FIRE PATH <<<'
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Remove-FireMarkedBlock $Path $start $end
    $content = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    if ($content -and -not $content.EndsWith("`n")) { $content += "`n" }
    $content += "$start`n$Line`n$end`n"
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}

function Get-FireInstallMetadata {
    param([string]$Uri)

    try { return Invoke-RestMethod -Uri $Uri -TimeoutSec 30 }
    catch {
        $reason = $_.Exception.Message
        if ($_.ErrorDetails) {
            try {
                $details = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($details.PSObject.Properties['message'] -and $details.message) { $reason += " $($details.message)" }
            }
            catch { }
        }
        throw "Cannot check tool versions at '$Uri'. $reason Retry 'fire install'."
    }
}

function Get-FireImageDigests {
    param($Tag)

    if (-not $Tag.PSObject.Properties['images'] -or -not $Tag.images) { return }
    $digests = @($Tag.images | ForEach-Object { [string]$_.digest } | Sort-Object)
    if (@($digests | Where-Object { $_ -notmatch '^sha256:[a-f0-9]{64}$' }).Count) { return }
    return $digests
}

function Get-FireLatestImage {
    param([ValidateSet('mcr.microsoft.com/mssql/server', 'postgres', 'flyway/flyway')][string]$Repository)

    if ($Repository -eq 'mcr.microsoft.com/mssql/server') {
        $metadata = Get-FireInstallMetadata 'https://mcr.microsoft.com/v2/mssql/server/tags/list'
        $tag = $metadata.tags | Where-Object { $_ -match '^\d{4}-latest$' } | Sort-Object -Descending | Select-Object -First 1
        if (-not $tag) { throw 'No stable SQL Server image found in Microsoft Container Registry.' }
        try {
            $manifest = Invoke-WebRequest -Method Head -Uri "https://mcr.microsoft.com/v2/mssql/server/manifests/$tag" -TimeoutSec 30 -Headers @{
                Accept = 'application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json'
            }
            $digest = [string]($manifest.Headers['Docker-Content-Digest'] | Select-Object -First 1)
        }
        catch { throw "Cannot check the SQL Server image. Check your network and retry 'fire install'." }
    }
    else {
        $namespace, $name = if ($Repository -eq 'postgres') { @('library', 'postgres') } else { $Repository.Split('/') }
        $base = "https://hub.docker.com/v2/namespaces/$namespace/repositories/$name/tags"
        $latest = Get-FireInstallMetadata "$base/latest"
        $digest = [string]$latest.digest
        if ($digest -notmatch '^sha256:[a-f0-9]{64}$') { throw "No image digest found for ${Repository}:latest." }
        $latestImageDigests = @(Get-FireImageDigests $latest)
        $uri = "$base`?page_size=100"
        $tag = $null
        do {
            $page = Get-FireInstallMetadata $uri
            $release = $page.results | Where-Object {
                if ($_.name -notmatch '^\d+(?:\.\d+){0,2}$' -or $_.digest -notmatch '^sha256:[a-f0-9]{64}$') { return $false }
                if ($_.digest -ceq $digest) { return $true }
                $imageDigests = @(Get-FireImageDigests $_)
                return $latestImageDigests.Count -gt 0 -and $imageDigests.Count -eq $latestImageDigests.Count -and
                    ($imageDigests -join ',') -ceq ($latestImageDigests -join ',')
            } |
                Sort-Object -Property @{ Expression = { [regex]::Replace($_.name, '\d+', { param($number) $number.Value.PadLeft(20, '0') }) }; Descending = $true } |
                Select-Object -First 1
            if ($release) { $tag = [string]$release.name; $digest = [string]$release.digest; break }
            $uri = $page.next
        } while ($uri)
        if (-not $tag) { throw "No versioned image found for ${Repository}:latest. Retry 'fire install'." }
    }
    if ($digest -notmatch '^sha256:[a-f0-9]{64}$') { throw "No image digest found for ${Repository}:$tag." }
    return [PSCustomObject]@{ Image = "${Repository}:$tag"; Digest = $digest }
}

function Install-FireImage {
    param([string]$Repository)

    $release = Get-FireLatestImage $Repository
    $local = Invoke-FireNative docker @('image', 'inspect', $release.Image, '--format', '{{json .RepoDigests}}') -AllowFailure
    if ($LASTEXITCODE -eq 0 -and @($local | ConvertFrom-Json | Where-Object { $_.EndsWith("@$($release.Digest)", [StringComparison]::Ordinal) }).Count) {
        Write-FireText "$($release.Image) is current."
        return
    }
    $pullArguments = @('pull')
    if ($Repository -eq 'mcr.microsoft.com/mssql/server') { $pullArguments += @('--platform', 'linux/amd64') }
    $pullArguments += $release.Image
    Invoke-FireNative docker $pullArguments -Activity "Pulling $($release.Image)" | Out-Null
    Write-FireText "$($release.Image) installed."
}

function Install-FirePgDiffImage {
    $release = Get-FireInstallMetadata 'https://proxy.golang.org/github.com/stripe/pg-schema-diff/@latest'
    if ($release.Version -notmatch '^v\d+\.\d+\.\d+$') { throw 'No stable pg-schema-diff release found.' }
    $Script:PgDiffImage = "fire/pg-schema-diff:$($release.Version.Substring(1))"
    Invoke-FireNative docker @('image', 'inspect', $Script:PgDiffImage) -AllowFailure | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-FireText "$Script:PgDiffImage is current."
        return
    }
    $dockerfileRoot = Join-Path $Script:FireSourceRoot 'tools/pg-schema-diff'
    Invoke-FireNative docker @('build', '--pull', '--build-arg', "PG_SCHEMA_DIFF_VERSION=$($release.Version)",
        '--tag', $Script:PgDiffImage, $dockerfileRoot) -Activity 'Building pg-schema-diff' | Out-Null
    Write-FireText "$Script:PgDiffImage installed."
}

function Install-FireSqlPackage {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'FIRE install requires the .NET SDK to install SqlPackage.'
    }
    $index = Get-FireInstallMetadata 'https://api.nuget.org/v3/index.json'
    $search = $index.resources | Where-Object { $_.'@type' -eq 'SearchQueryService' } | Select-Object -ExpandProperty '@id' -First 1
    if (-not $search) { throw 'No NuGet search service found.' }
    $metadata = Get-FireInstallMetadata "$search`?q=packageid:microsoft.sqlpackage&prerelease=false&semVerLevel=2.0.0"
    $version = $metadata.data | Where-Object { $_.id -ieq 'microsoft.sqlpackage' } | Select-Object -ExpandProperty version -First 1
    if ($version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'No stable SqlPackage release found on NuGet.' }
    $globalTools = Invoke-FireNative dotnet @('tool', 'list', '--global')
    $installed = $globalTools -match '(?im)^\s*microsoft\.sqlpackage\s+(?<version>\S+)'
    if ($installed -and $Matches.version -ceq $version) {
        Write-FireText "SqlPackage $version is current."
    }
    else {
        $action = if ($installed) { 'update' } else { 'install' }
        Invoke-FireNative dotnet @('tool', $action, '--global', 'microsoft.sqlpackage', '--version', $version) -Activity 'Installing SqlPackage' | Out-Null
        Write-FireText "SqlPackage $version installed."
    }
}

function Install-FireDependencies {
    Assert-FireDockerRunning
    Install-FireSqlPackage
    Install-FireImage 'mcr.microsoft.com/mssql/server'
    Install-FireImage 'postgres'
    Install-FireImage 'flyway/flyway'
    Install-FirePgDiffImage
}

function Write-FireShellLauncher {
    param([string]$Bin, [string]$Entry)

    $launcher = Join-Path $Bin 'fire'
    $escaped = $Entry.Replace("'", "'\''")
    $content = "#!/bin/sh`nexec pwsh -NoProfile -File '$escaped' `"`$@`"`n"
    [IO.File]::WriteAllText($launcher, $content, [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { Invoke-FireNative chmod @('755', $launcher) | Out-Null }
    return $launcher
}

function Write-FireWindowsLauncher {
    param([string]$Bin, [string]$Entry)

    $launcher = Join-Path $Bin 'fire.cmd'
    $wrapper = Join-Path $Bin 'fire-launcher.ps1'
    $escaped = $Entry.Replace("'", "''")
    [IO.File]::WriteAllText($wrapper, "& pwsh -NoProfile -File '$escaped' @args`r`nexit `$LASTEXITCODE`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($launcher, "@echo off`r`npwsh -NoProfile -File `"%~dp0fire-launcher.ps1`" %*`r`n", [Text.Encoding]::ASCII)
    Write-FireShellLauncher $Bin $Entry | Out-Null
    return $launcher
}

function Remove-FireWindowsLauncher {
    param([string]$Bin, [string]$Entry)

    $launcher = Join-Path $Bin 'fire.cmd'
    $wrapper = Join-Path $Bin 'fire-launcher.ps1'
    $shellLauncher = Join-Path $Bin 'fire'
    if (-not (Test-Path -LiteralPath $launcher) -and -not (Test-Path -LiteralPath $wrapper) -and
        -not (Test-Path -LiteralPath $shellLauncher)) { return }
    $escaped = $Entry.Replace("'", "''")
    if (((Test-Path -LiteralPath $launcher) -or (Test-Path -LiteralPath $wrapper)) -and
        (-not (Test-Path -LiteralPath $wrapper -PathType Leaf) -or
        -not ([IO.File]::ReadAllText($wrapper)).Contains("& pwsh -NoProfile -File '$escaped' @args") -or
        ((Test-Path -LiteralPath $launcher) -and
            -not ([IO.File]::ReadAllText($launcher)).Contains('pwsh -NoProfile -File "%~dp0fire-launcher.ps1" %*')))) {
        throw "Launcher '$launcher' does not point to this FIRE checkout."
    }
    Assert-FireShellLauncher $shellLauncher $Entry
    if (Test-Path -LiteralPath $wrapper) { Remove-Item -LiteralPath $wrapper -Force }
    if (Test-Path -LiteralPath $launcher) { Remove-Item -LiteralPath $launcher -Force }
    if (Test-Path -LiteralPath $shellLauncher) { Remove-Item -LiteralPath $shellLauncher -Force }
}

function Assert-FireShellLauncher {
    param([string]$Launcher, [string]$Entry)

    if (-not (Test-Path -LiteralPath $Launcher)) { return }
    $escaped = $Entry.Replace("'", "'\''")
    $content = [IO.File]::ReadAllText($Launcher)
    if (-not $content.Contains("exec pwsh -NoProfile -File '$escaped' ")) {
        throw "Launcher '$Launcher' does not point to this FIRE checkout."
    }
}

function Remove-FireUnixLauncher {
    param([string]$Launcher, [string]$Entry)

    Assert-FireShellLauncher $Launcher $Entry
    if (Test-Path -LiteralPath $Launcher) { Remove-Item -LiteralPath $Launcher -Force }
}

function Get-FireUnixPathProfiles {
    param([string]$HomeDirectory = $HOME, [string]$PowerShellProfile = $PROFILE.CurrentUserAllHosts,
        [string]$ZshDirectory = $env:ZDOTDIR, [string]$ConfigDirectory = $env:XDG_CONFIG_HOME)

    $exportLine = 'export PATH="$HOME/.local/bin:$HOME/.dotnet/tools:$PATH"'
    foreach ($name in @('.profile', '.bashrc', '.bash_profile', '.bash_login')) {
        $path = Join-Path $HomeDirectory $name
        if ($name -in @('.profile', '.bashrc') -or (Test-Path -LiteralPath $path)) {
            [PSCustomObject]@{ Path = $path; Line = $exportLine }
        }
    }
    if (-not $ZshDirectory) { $ZshDirectory = $HomeDirectory }
    if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $HomeDirectory '.config' }
    [PSCustomObject]@{ Path = Join-Path $ZshDirectory '.zshrc'; Line = $exportLine }
    [PSCustomObject]@{ Path = Join-Path $ConfigDirectory 'fish/config.fish'; Line = 'fish_add_path --path $HOME/.local/bin $HOME/.dotnet/tools' }
    [PSCustomObject]@{ Path = $PowerShellProfile; Line = '$env:PATH = "$HOME/.local/bin:$HOME/.dotnet/tools:$env:PATH"' }
}

function Install-Fire {
    Install-FireDependencies
    $bin = Get-FireLauncherDirectory
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $entry = Join-Path $Script:FireSourceRoot 'fire.ps1'
    if ($IsWindows) {
        $launcher = Write-FireWindowsLauncher $bin $entry
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $segments = @($userPath -split ';' | Where-Object { $_ })
        if ($bin -notin $segments) {
            try {
                [Environment]::SetEnvironmentVariable('Path', (($segments + $bin) -join ';'), 'User')
            }
            catch {
                throw "Cannot add FIRE launcher directory '$bin' to your user PATH. Check Windows account permissions and retry."
            }
        }
        if ($bin -notin @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')) {
            throw "FIRE launcher directory '$bin' was not saved in your user PATH."
        }
    }
    else {
        $launcher = Write-FireShellLauncher $bin $entry
        foreach ($profileEntry in Get-FireUnixPathProfiles) { Add-FirePathBlock $profileEntry.Path $profileEntry.Line }
    }
    Write-FireLogo
    Write-FireText "FIRE launcher installed: $launcher"
    Write-FireText 'Restart the app hosting your terminal to use FIRE from any repository.'
}

function Uninstall-Fire {
    $bin = Get-FireLauncherDirectory
    $launcher = Join-Path $bin $(if ($IsWindows) { 'fire.cmd' } else { 'fire' })
    if ($IsWindows) {
        Remove-FireWindowsLauncher $bin (Join-Path $Script:FireSourceRoot 'fire.ps1')
    }
    else {
        Remove-FireUnixLauncher $launcher (Join-Path $Script:FireSourceRoot 'fire.ps1')
    }
    if ($IsWindows) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $segments = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin })
        [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), 'User')
    }
    else {
        foreach ($profileEntry in Get-FireUnixPathProfiles) {
            Remove-FireMarkedBlock $profileEntry.Path '# >>> FIRE PATH >>>' '# <<< FIRE PATH <<<'
        }
    }
    Write-FireText 'FIRE launcher removed. Repository databases and caches remain.'
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAczSVXijc5qL2G
# AViDvs0DQio0p20pYDBITRi7ZzsIxKCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
# vUoLyWB3/qUcMA0GCSqGSIb3DQEBCwUAMDIxETAPBgNVBAoMCEZJUkUgQ0xJMR0w
# GwYDVQQDDBRBa2Fyc2hhbiBHbmFuZXN3YXJhbjAeFw0yNjEwMDExOTQwMjRaFw0y
# OTEwMDExOTUwMjNaMDIxETAPBgNVBAoMCEZJUkUgQ0xJMR0wGwYDVQQDDBRBa2Fy
# c2hhbiBHbmFuZXN3YXJhbjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGB
# AMajm3R68g1AfVGSh7fwCbfRPjrlkdJQI3egCmP5Fp20yw9hRvtmaWR0h+iX1BoI
# sFOfYJ9+LnCK3OdVtEHdn+HkFzm4URHNMbUXlMF5HM8cXhYccuAxw3JR4yy/OH9B
# qd8tBl47/RVe+TjZJaURHhu3V682PT4q5rUZ3FLS0bRUAX2q1iR67GHi4EMaR0EP
# KepuvKdiZ2B3TMUR/poojgsStQ2rRPxv6YGp3yCKz2N44TmP7CtahnrpyNfZVcwk
# IbVHwm2YSH/pTcFJC8k3vki1YMupxg3gibazKwtvB27PZbNIvCK1HPrJK0pDQ2bk
# 54cIgLjdt2WORE63Z6TliIF+MIOARn8Ieg2GtbN7kx41ZADwCaB9+Nk2NSQGcEL9
# c8kzKu0N1leO2Qj67930uUyfSs3TFs29TSpypGxEBMFEB1thT90p9zlwPtEqGyYi
# d7m3NGrJm0aRGK/qih7jVvP/uCRZdjZTB88mS3ysDEgS/MIl3VYNnrFbCtsym4lA
# fQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# HQYDVR0OBBYEFKuiyNwVMOzXprxVCSOyrah6gLjNMA0GCSqGSIb3DQEBCwUAA4IB
# gQArr4jHG3ikrMdbv3XWzfsr55rOXAcelMKY4fsdE9PIczCFPlhetfr07HAUeFQn
# 1v4z0awVOFy8C4BnO/uIWW0qUbFiD5si89Wj0Hh4ytUg5057WJcqwlHcUPb9FEWy
# QspGrxo54fiJn1oi5oLC5fMCess9+XACTBPW2YSHEs4Zwmc8WvtBwleXqoXlsVf4
# EhGyDEE6vXIX9wzApaJC3yG5Xn/7uNwWSdJXvUkzK9zPtP89RBANxr5p/ewK5Crb
# LJIO4PelzJlxPQfvTpiv/Dzzd39gRRY26NgTHRE2Lr7I2CqH+zLtvReE7veK0KFk
# 9BKAlFYZQ9VyA5suBwu4ZQmvCQXhQ1HIsP3Tmk5xKgNFwHwrp5mocjJldEHKxOZ8
# 0SYuPd3p3MfmERggRgY2aArUg8xHCvR83crr7CBijwWMGw4LGTK23vuwSJOE2hsO
# y9t+7zeixXH1X3QUyoYU9E/Xi4zfj7HfqQO266kQ5zxvsUiZBGR3U2eBYkRAiFcQ
# giAwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUA
# MGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQg
# Um9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqcl
# LskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YF
# PFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34LzB4TmdDttceIt
# DBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+xembud8hIqGZX
# V59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1
# ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2Tox
# RJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdp
# ekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF
# 30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9
# t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQ
# UOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXk
# aS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1Ud
# DgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEt
# UYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsG
# AQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0
# dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAw
# DQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979XB72arKGHLOyF
# XqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4kvFIDyE7QKt76
# LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8L
# punyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2
# CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si
# /xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQwgga0MIIEnKADAgEC
# AhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcw
# MDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZ
# loMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM
# 2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj
# 7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQ
# Sku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZ
# lDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+
# 8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRx
# ykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yG
# OP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqI
# MRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm
# 1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBj
# UwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729T
# SunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4c
# D08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUF
# BwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEG
# CCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAX
# MAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaA
# HP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQ
# M2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt
# 6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7
# bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmS
# Nq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69
# M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnF
# RsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmM
# Thi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oa
# Qf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx
# 9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3
# /BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+
# RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# VGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAw
# MDAwMFoXDTM3MTEwNDIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRp
# Z2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBU
# aW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJr
# FIhy24fcpKXlgRiky4WAawDfU3YP0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZ
# BcmJCcN0ASURML5uFIS80sZsDwO3BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol
# 9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6Xp
# CtklTJXeIg283hw7TmmsZXR+SMbjbrEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVyn
# b/whITPAo9b75Zr4Ta6Mj3URm26QZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74
# lIT/ug0eeOzmZ6QTFg33otX+bFRsIolvykE1jive4PuESaT8zzVeFWDAMDtozNgL
# ctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYK
# D1Nkddsnb/ItVKi/2nXpQNMu1PT5prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj
# 3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwb
# rJvfpklkZQvw3+kv3vUPItdwroczk9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGj
# ggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+
# 9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8E
# BAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGF
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUH
# MAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBW
# MFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkw
# FzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTph
# Hp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWyg
# LzlT12os5ipDCy35RBCg2UMeApEtrfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4
# d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1
# iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3G
# hTiy0PxpawPtGRyaBVGzq+UiTfM8pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA
# /+t0YcT2oRVBm3JETjajHug2AL+v5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+q
# bceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLR
# aRT7LCkRYVnhA2D73FLje1O5b3HR5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg
# /JgwtKfZM5dqO94lbUveOiJBI+xZEbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2Vh
# kSKSXjDbD6rgg39H5Mh7QfieAIjWagkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6
# jATlWJdYeeDRGCyatf8R1hSjzSvdN8yWQPT9gzGCBaIwggWeAgEBMEYwMjERMA8G
# A1UECgwIRklSRSBDTEkxHTAbBgNVBAMMFEFrYXJzaGFuIEduYW5lc3dhcmFuAhAq
# 44+Z0deOvUoLyWB3/qUcMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPJqX613XkvMIHzj
# ZAX5xitsSR847ugPBcGc9FUinqv/MA0GCSqGSIb3DQEBAQUABIIBgHQ0Z60vOz6U
# 2qfw/Q+pl+rBqQzX2/7mDyjrCll7tFh1tMjXhOKDSX6ilWe1BN9wrhzJj+DQEQoA
# xAByvd9Iqsg4zetbBSRNwZEdRlsBGEXswosHawSQY/+K9CWBuIn8v4EfDNNAe1d5
# GlNMXbOMSSRFJrAd6FqunAGIBEZIgJc5Zb0iP9bkLCYoHuvvmmUbOicbFksMvRM2
# Via3CpUtxHQIFzAT+U7E0hwyUcC0BOs0PRDIfEJBxWU6dg4JZd2wCQJg+Ffx/z/O
# 91Adx6355eTbjIxJ9zVnwJOdNz0Lc5ILVDe2GJ9s3GjqxBt0Bo3e9Djhk8BBIjyu
# pi6CzCmpzI0OK+ZwogPq/NjyycrFtSttK1p+GXuHI8KSzN0YNnko3va+VDm3bbTZ
# 0/iSD8JKWqSaSAqKcfXDfEbHTrNMzmUz6uN0C1QGjUokpl8rx2OYl12CfYHxwWsW
# hhYz5wsdE6nGtQxTKwJCQeSwaFqXSYyD3HR0NYqijGW8Exmjn9f2K6GCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjRaMC8GCSqGSIb3DQEJBDEiBCA/
# h5OoSUtIYdtEDKjoQTMMgnbNmE0WNoCcXhNTRhX04DANBgkqhkiG9w0BAQEFAASC
# AgBly1IZ6sOeysn3/RsHwc2htiaSSy4iUkUBPxqvpGxUcNwINaAzxxxBqBUKwm54
# bMHCDRaueorkQfL5Mhwsw9VB1IYuy0OdaX19f3DfFhFPr6LMazYQGbu6LZMlhma2
# CAlM8pawaCe4F29e+q8n3rfN38bK1609HA9BseKWI4arhxDAAbpFbG8A00MQKWvU
# 1V/sGY2WAUVQGgA3n35I4b/1knlDneu9JSHBVP7Zca5K4xBMFkFSLswNO3gxhpX6
# yFBYOeBxmM9qKiRMpjLJW6v1DFlOlvFvS7EGZCTBQfjhZc2ncKZEpVIpA354NBzU
# 2B8jTAMORRxjsK0BGzSPhmxMFk4a0kZDU4qDRn8Ld0YyLMcgI6IqoPQ/Svr/OIUL
# 2BCjveBAmufex/yQRSveqw3yzQD6BH3XjXZKjvLzg6dcRRTbCXnnUmku3fN3sEHK
# ep73YrSWELRM7JTVn6tk+jSIl/abtvYla1snqnhAav1ml4ZC3l4proSxDOZwoEG1
# dc5LJ2Q7VVn/43wa47ykClPTiZwsR0xNzUGEGxdck1gheusaAN0y6VeLcYznakPX
# XTYVr3lObhP2M3Kntzgvjt0x7jarMfv+v1seicr4DUoCJ4V0xTcHAX1kfRNUs0s5
# gEKJnJzPOqEEUwLJI7wp6IFVCXNouAA5W8RqquIpMw0PvQ==
# SIG # End signature block
