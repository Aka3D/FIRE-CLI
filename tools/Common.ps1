Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Script:FireSourceRoot = Split-Path -Parent $PSScriptRoot
$Script:FlywayImage = 'flyway/flyway:13.7.0'
$Script:PgDiffImage = $null
$Script:FireBrewing = $null

function Test-FireTerminal {
    param([switch]$Interactive, [switch]$ErrorStream)

    if ($env:TERM -eq 'dumb' -or $env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal -or
        $PSStyle.OutputRendering -eq 'PlainText') { return $false }
    if ($Interactive -and [Console]::IsInputRedirected) { return $false }
    if ($ErrorStream) { return -not [Console]::IsErrorRedirected }
    return -not [Console]::IsOutputRedirected
}

function Get-FireSupportedEngines {
    param([string]$Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())

    switch ($Architecture) {
        'X64' { return @('sqlserver', 'postgresql') }
        'Arm64' { return @('postgresql') }
        default { throw 'FIRE requires an x64 or ARM64 machine.' }
    }
}

function Assert-FireEngineSupported {
    param([ValidateSet('sqlserver', 'postgresql')][string]$Engine)

    if ($Engine -notin @(Get-FireSupportedEngines)) {
        throw 'SQL Server requires an x64 machine. Use PostgreSQL on ARM64.'
    }
}

function Format-FireOrange {
    param([string]$Text)

    if (-not (Test-FireTerminal)) { return $Text }
    return "$($PSStyle.Foreground.FromRgb(255, 96, 0))$Text$($PSStyle.Reset)"
}

function Write-FireOrange {
    param([string]$Text)

    Write-Host (Format-FireOrange $Text)
}

function Format-FireBrand {
    param([string]$Text, [switch]$ErrorStream)

    if (-not (Test-FireTerminal -ErrorStream:$ErrorStream)) { return $Text }
    return $Text -creplace '\bFIRE\b', "$($PSStyle.Foreground.FromRgb(255, 96, 0))FIRE$($PSStyle.Reset)"
}

function Write-FireText {
    param([Parameter(ValueFromPipeline)][string]$Text)

    process { Write-Host (Format-FireBrand $Text) }
}

function Write-FireCommandHeader {
    param([string]$Command)

    Write-FireOrange "FIRE $Command"
    Write-Host
}

function Write-FireLogo {
    Write-FireOrange @'
 (     (    (
 )\ )  )\ ) )\ )
(()/( (()/((()/( (
 /(_)) /(_))/(_)))\
(_))_|(_)) (_)) ((_)
| |_  |_ _|| _ \| __|
| __|  | | |   /| _|
|_|   |___||_|_\|___|
'@
}

function Write-FireActivityFrame {
    param([string]$Status)

    if (-not (Test-FireTerminal)) { return }
    $plain = $Status.Replace("`r", ' ').Replace("`n", ' ')
    $maxWidth = [Math]::Max(0, [Console]::WindowWidth - 1)
    if ($plain.Length -gt $maxWidth) { $plain = $plain.Substring(0, $maxWidth) }
    [Console]::Write("`r`e[2K$plain")
}

function Clear-FireActivity {
    if ($Script:FireBrewing -or -not (Test-FireTerminal)) { return }
    [Console]::Write("`r`e[2K")
}

function Invoke-FireNative {
    param([string]$File, [string[]]$Arguments, [switch]$AllowFailure, [string]$Activity, [scriptblock]$OutputLineAction)

    if ($Script:FireBrewing -or $OutputLineAction -or ($Activity -and (Test-FireTerminal))) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $File
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $activityShown = $false
        $processStarted = $false
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = [Collections.Generic.List[string]]::new()
        try {
            [void]$process.Start()
            $processStarted = $true
            if ($Activity -and $Script:FireBrewing -and -not $Script:FireBrewing.Result) { $Script:FireBrewing.Activity = $Activity }
            $streams = @(
                [PSCustomObject]@{ Reader = $process.StandardOutput; Task = $process.StandardOutput.ReadLineAsync(); IsError = $false },
                [PSCustomObject]@{ Reader = $process.StandardError; Task = $process.StandardError.ReadLineAsync(); IsError = $true }
            )
            do {
                foreach ($stream in $streams) {
                    # Drain both streams fairly; SQL debug output can arrive faster than rendering.
                    for ($lineNumber = 0; $lineNumber -lt 100 -and $stream.Task -and $stream.Task.IsCompleted; $lineNumber++) {
                        $line = $stream.Task.GetAwaiter().GetResult()
                        if ($null -eq $line) { $stream.Task = $null; break }
                        if (-not $OutputLineAction -or (& $OutputLineAction $line $stream.IsError)) {
                            $output.Add($line)
                        }
                        $stream.Task = $stream.Reader.ReadLineAsync()
                    }
                }
                if ($Script:FireBrewing) { Update-FireBrewing }
                elseif ($Activity -and (Test-FireTerminal) -and $watch.ElapsedMilliseconds -ge 120) {
                    Write-FireActivityFrame "$Activity ($([Math]::Floor($watch.Elapsed.TotalSeconds))s)"
                    $activityShown = $true
                }
                $reading = @($streams | Where-Object { $null -ne $_.Task }).Count -gt 0
                if (-not @($streams | Where-Object { $_.Task -and $_.Task.IsCompleted }).Count) {
                    Start-Sleep -Milliseconds 20
                }
            }
            while ($reading -or -not $process.HasExited)
            $process.WaitForExit()
            $global:LASTEXITCODE = $process.ExitCode
            $text = $output -join "`n"
            if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
                throw "$File failed (exit $($process.ExitCode)): $($text.Trim())"
            }
            return $text.TrimEnd()
        }
        finally {
            if ($activityShown) { Clear-FireActivity }
            if ($processStarted -and -not $process.HasExited) { $process.Kill($true) }
            $process.Dispose()
            $watch.Stop()
        }
    }

    $output = & $File @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "$File failed (exit $LASTEXITCODE): $($output.Trim())"
    }
    return $output.TrimEnd()
}

function Assert-FireDockerRunning {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker CLI is missing. Install Docker Desktop or Docker Engine, then retry.'
    }
    try {
        $dockerOs = Invoke-FireNative docker @('info', '--format', '{{.OSType}}')
    }
    catch {
        throw 'Cannot connect to Docker. Start Docker Desktop or Docker Engine, then retry.'
    }
    if ($dockerOs.Trim() -ne 'linux') {
        throw 'FIRE requires Linux containers. Switch Docker Desktop to Linux containers, then retry.'
    }
}

function Get-FireLocalImages {
    param([string]$Repository, [string]$TagPattern)

    $images = Invoke-FireNative docker @('image', 'ls', '--format', '{{.Repository}}:{{.Tag}}')
    $unique = @($images -split "`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match "^$([regex]::Escape($Repository)):$TagPattern$" } |
        Sort-Object -Unique)
    return @($unique | Sort-Object -Property @{
        Expression = { [regex]::Replace($_, '\d+', { param($number) $number.Value.PadLeft(20, '0') }) }
        Descending = $true
    })
}

function Get-FireHash {
    param([string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-FireGitRoot {
    param([string]$Start = (Get-Location).Path)

    $result = & git -C $Start rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        throw 'FIRE needs a Git repository. Run this command inside a checkout.'
    }
    return [IO.Path]::GetFullPath([string]$result)
}

function Get-FireProject {
    param([string]$Start = (Get-Location).Path)

    $root = Get-FireGitRoot $Start
    $directory = [IO.Path]::GetFullPath($Start)
    while ($true) {
        $configPath = Join-Path $directory 'db/fire.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            return Read-FireProject $directory
        }
        if ($directory -eq $root) { break }
        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory -or -not $parent.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $directory = $parent
    }
    throw "No db/fire.json found between '$Start' and repository root '$root'. Run 'fire init' at the repository root."
}

function Assert-FireName {
    param([string]$Name, [string]$Kind = 'name')

    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,62}$') {
        throw "Invalid $Kind '$Name'. Use letters, digits, and underscores. Start with a letter."
    }
}

function Assert-FireDatabaseName {
    param([string]$Name, [ValidateSet('sqlserver', 'postgresql')][string]$Engine)

    Assert-FireName $Name 'database name'
    $systemDatabase = if ($Engine -eq 'sqlserver') { $Name -in @('master', 'model', 'msdb', 'tempdb') }
        else { $Name -cin @('postgres', 'template0', 'template1') }
    if ($systemDatabase) {
        $engineName = if ($Engine -eq 'sqlserver') { 'SQL Server' } else { 'PostgreSQL' }
        throw "'$Name' is a $engineName system database. Choose a different project database name."
    }
}

function Assert-FireContainerName {
    param([string]$Name)

    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,62}$') {
        throw "Invalid Docker container name '$Name'. Start with a letter and use letters, digits, underscores, periods, or hyphens."
    }
}

function Read-FireProject {
    param([string]$Root)

    $dbRoot = Join-Path $Root 'db'
    $path = Join-Path $dbRoot 'fire.json'
    $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 30
    if (-not $config.PSObject.Properties['port']) { $config | Add-Member -NotePropertyName port -NotePropertyValue $null }
    if (-not $config.PSObject.Properties['flywayImage']) { $config | Add-Member -NotePropertyName flywayImage -NotePropertyValue $Script:FlywayImage }
    if ($config.version -ne 1) { throw "Unsupported FIRE config version in '$path'." }
    if ($config.engine -notin @('sqlserver', 'postgresql')) { throw "Invalid database engine in '$path'." }
    Assert-FireContainerName ([string]$config.containerName)
    if ([string]::IsNullOrWhiteSpace([string]$config.image) -or [string]$config.image -notmatch ':[0-9][A-Za-z0-9_.-]*$') {
        throw "Specify a versioned database image in '$path'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.flywayImage) -or [string]$config.flywayImage -notmatch ':[0-9][A-Za-z0-9_.-]*$') {
        throw "Specify a versioned Flyway image in '$path'."
    }
    if ($null -ne $config.port) {
        $port = 0
        if (-not [int]::TryParse([string]$config.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw "Port in '$path' must be an integer from 1-65535 or null."
        }
        $config.port = $port
    }
    $databases = @($config.databases)
    if ($databases.Count -eq 0) { throw "Define at least one database in '$path'." }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($database in $databases) {
        if (-not $database.PSObject.Properties['seedTables']) {
            $database | Add-Member -NotePropertyName seedTables -NotePropertyValue @()
        }
        Assert-FireDatabaseName ([string]$database.name) $config.engine
        if (-not $seen.Add([string]$database.name)) { throw "Duplicate database '$($database.name)'." }
        foreach ($table in @($database.seedTables)) {
            if ([string]$table.name -notmatch '^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*$') {
                throw "Seed table '$($table.name)' must be schema.table."
            }
            if (@($table.key).Count -eq 0) { throw "Seed table '$($table.name)' needs key columns." }
            foreach ($key in @($table.key)) { Assert-FireName ([string]$key) 'key column' }
        }
        $migrationPath = Join-Path $dbRoot "migrations/$($database.name)"
        if (-not (Test-Path -LiteralPath $migrationPath -PathType Container)) {
            throw "Migration folder missing: '$migrationPath'."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $migrationPath 'V00001__Baseline.sql') -PathType Leaf)) {
            throw "Baseline V00001__Baseline.sql missing for '$($database.name)'."
        }
    }
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $id = (Get-FireHash $canonicalRoot.ToLowerInvariant()).Substring(0, 16)
    return [PSCustomObject]@{
        Root = $canonicalRoot
        DbRoot = $dbRoot
        LocalRoot = Join-Path $dbRoot '.fire'
        Config = $config
        Id = $id
        Container = [string]$config.containerName
        Volume = "fire_${id}_data"
    }
}

function Get-FireDatabase {
    param($Project, [string]$Name)

    $databases = @($Project.Config.databases)
    if (-not $Name) {
        if ($databases.Count -ne 1) { throw 'Specify a database name. This repository defines several.' }
        return $databases[0]
    }
    $database = @($databases | Where-Object { $_.name -ieq $Name })
    if ($database.Count -ne 1) { throw "Unknown database '$Name'." }
    return $database[0]
}

function Get-FireMigrationsPath {
    param($Project, $Database)
    return Join-Path $Project.DbRoot "migrations/$($Database.name)"
}

function Get-FireCredentials {
    param($Project, [switch]$Create)

    $path = Join-Path $Project.LocalRoot 'credentials.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $credentials = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $expected = if ($Project.Config.engine -eq 'sqlserver') { 'sa' } else { 'postgres' }
        if ($credentials.user -ne $expected -or [string]::IsNullOrWhiteSpace([string]$credentials.password)) {
            throw "Invalid FIRE credentials in '$path'."
        }
        return $credentials
    }
    if (-not $Create) { throw "Credentials missing: '$path'. Run 'fire up'." }
    if ((Get-Command docker -ErrorAction SilentlyContinue) -and (Get-FireContainerJson $Project.Container)) {
        throw "Credentials missing for existing FIRE container '$($Project.Container)'. Restore the file or remove the container explicitly."
    }
    New-Item -ItemType Directory -Path $Project.LocalRoot -Force | Out-Null
    $password = 'F!a1' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
    $credentials = [PSCustomObject]@{ user = $(if ($Project.Config.engine -eq 'sqlserver') { 'sa' } else { 'postgres' }); password = $password }
    [IO.File]::WriteAllText($path, ($credentials | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 600 $path | Out-Null }
    return $credentials
}

function Get-FireFingerprint {
    param($Project, $Database)

    $migrationPath = Get-FireMigrationsPath $Project $Database
    $files = @(Get-ChildItem -LiteralPath $migrationPath -File | Where-Object { $_.Name -match '\.sql(?:\.conf)?$' } | Sort-Object Name)
    $manifest = foreach ($file in $files) { "$($file.Name):$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)" }
    $container = Get-FireContainerJson $Project.Container
    $imageId = if ($container) { [string]$container.Image }
    else { Invoke-FireNative docker @('image', 'inspect', [string]$Project.Config.image, '--format', '{{.Id}}') }
    $seedConfig = $Database.seedTables | ConvertTo-Json -Depth 10 -Compress
    return Get-FireHash ((@($Project.Config.engine, $imageId, $Project.Config.flywayImage, $seedConfig) + $manifest) -join "`n")
}

function New-FireWorkDirectory {
    param($Project, [string]$Purpose)

    $root = Join-Path $Project.LocalRoot 'work'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $path = Join-Path $root "${Purpose}_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBzD9lgbFjsa6Mw
# Zi0CMe9Xu7QrNFbXTwVPSq+4W2hCVaCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEINVZCiVqBMxbC0/C
# W6YYsFbcsFh6OvN1+tlV0AfgSUv6MA0GCSqGSIb3DQEBAQUABIIBgCD4RpvUmGqF
# sq6jisgF2F7VFWjtyt4BPyt1/aBvBeBt8d6TcbNZBY0CBfZUKm2t39eBgHW5TrVX
# bpPUBkqyQ+azL2ehL4HmlBvcyxZ0sqtQNWYnOB9ftEfyaRH1oZ4KEFmURmhrALEt
# PJl93hcFvlzrmTn8lQNX4tjC5rtiskNj0P9mPv+xMwHq0l7B1VPGtYvnQGBCtA0P
# wh9R7Enr1B6QE0Ut9UzE4YFIgxpnYmk9Mk9dZMd7WZMCHEL+AvO2rUf84URi01Pa
# kx3H7V5svHgDUHaUF7eXHHcOLpeWzd0u4or8ZCKCYDzLxtBEjU0lf+TmFgFaHHeH
# Bx22esKLg8civlWobt0PqummA3l4xz/0xmjptNqX1+AlUw4Fqx/qiK/+NfoC+uau
# nFk9kKZlIVGbPEZ6mNFfrTBS/+Tia1eCPee65qOrKYx0pvd+Hb965XoEVTu88aNy
# v82zQY38jlpqZ/xsqUV1cKd3gigBaiMr7XBMkZN0RXGGV628StoA2KGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjNaMC8GCSqGSIb3DQEJBDEiBCAM
# /8ZR0PbZoQhyhSYGwC6Jm0EnFBkcr7stV4CgJXoegjANBgkqhkiG9w0BAQEFAASC
# AgAB7651AQ0mckWxH1fgkX5tptnJDbSipbdx2qDTMxF31E8cmrA09kV6PAekiuFX
# W3RIsyscMTG7g/sgvaoIw2c2aEMYDb4UmBfzAFtuqlKBNW/JJh59LOLlcx45seYD
# K906niEv+h9E+AJ74i62ALFMKZJX3nryrohmfqxeTh2bx3JB3NBeetxZwaCusnzI
# 7Fvs4Q9WSmqvrrcF8IaA6yzPT743PS4jBaS8D5TB0NguaFSqhnIOcmDBDZAn0rtb
# Pib7vXy67Y50ms2EMURY+aQidXEcq+raHxvLYL9gvNHccO/ZoyG0zQT9X6XZOCUV
# wxeUXNRPyeLhlyO9A9Blj0gvoVYZTKny/hlzWqqxzuht3FiTDqL8eKkCBR/7G0jc
# 9EoqTq4XVVkfEBIkkZ5+E0PpmlCCXmxLpE89yJkOnaedxAad/fy/ddZX2WloIMSs
# sndAT7hnIxrnbEg8fGVZQu9qUYufDaVtpnqrK0cZcx8/tri3FZ0ut7jLYnwRGraQ
# cYGc+q9RBuhNHOuszMI2EY/WEXEaMj/d4ZWz8tloYVCilkElFPScmbmbDxNMX7TA
# 8xhri+WXuO4UD45HLMyhzQQsd3KacaM7WGPWE2NJCZDZuxdlfCExcdFkUtTH3hmC
# JQ1cBCzme0I8/7wxr5Tp5uwMDGZg+fOYJaDbf7V7IkMIHw==
# SIG # End signature block
