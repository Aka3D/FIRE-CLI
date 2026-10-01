function Get-FireContainerJson {
    param([string]$Name)

    $output = & docker container inspect $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($output | ConvertFrom-Json)[0]
}

function Get-FireVolumeJson {
    param([string]$Name)

    $output = & docker volume inspect $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($output | ConvertFrom-Json)[0]
}

function Assert-FireOwnedContainer {
    param($Project, $Container)

    if (-not $Container -or $Container.Config.Labels.'fire.managed' -ne 'true' -or
        $Container.Config.Labels.'fire.project' -ne $Project.Id) {
        throw "Container '$($Project.Container)' is not owned by this FIRE repository."
    }
    $volume = Get-FireVolumeJson $Project.Volume
    if (-not $volume -or $volume.Labels.'fire.managed' -ne 'true' -or $volume.Labels.'fire.project' -ne $Project.Id) {
        throw "Volume '$($Project.Volume)' is not owned by this FIRE repository."
    }
}

function Get-FirePort {
    param($Project, $Container)

    $internalPort = if ($Project.Config.engine -eq 'sqlserver') { '1433/tcp' } else { '5432/tcp' }
    $binding = $Container.NetworkSettings.Ports.PSObject.Properties[$internalPort]
    if (-not $binding -or @($binding.Value).Count -ne 1) {
        if ($null -ne $Project.Config.port) { throw "Fixed host port $($Project.Config.port) could not be published. Check for a port conflict." }
        throw "Container has no single published $internalPort port."
    }
    if ($binding.Value[0].HostIp -ne '127.0.0.1') { throw 'FIRE container port must be bound to 127.0.0.1.' }
    return [int]$binding.Value[0].HostPort
}

function Get-FireSqlcmd {
    param([string]$Container)

    foreach ($path in @('/opt/mssql-tools18/bin/sqlcmd', '/opt/mssql-tools/bin/sqlcmd')) {
        & docker exec $Container test -x $path 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $path }
    }
    throw "sqlcmd is missing in container '$Container'."
}

function Invoke-FireSqlServer {
    param([string]$Container, [string]$Password, [string]$Database = 'master', [string]$Query, [switch]$Wide, [string]$User = 'sa', [string]$Activity)

    $sqlcmd = Get-FireSqlcmd $Container
    $args = @('exec', '-e', "SQLCMDPASSWORD=$Password", $Container, $sqlcmd, '-S', 'localhost', '-U', $User, '-d', $Database, '-b', '-r', '1', '-s', '|', '-w', '65535')
    if ($Wide) { $args += @('-y', '0') }
    else { $args += @('-h', '-1', '-W') }
    if ($sqlcmd -like '*tools18*') { $args += '-C' }
    $args += @('-Q', "SET NOCOUNT ON; $Query")
    return Invoke-FireNative docker $args -Activity $Activity
}

function Invoke-FirePostgres {
    param([string]$Container, [string]$Password, [string]$Database = 'postgres', [string]$Query, [string]$Activity, [string]$User = 'postgres')

    return Invoke-FireNative docker @('exec', '-e', "PGPASSWORD=$Password", $Container, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-A', '-t', '-U', $User, '-d', $Database, '-c', $Query) -Activity $Activity
}

function Wait-FireServer {
    param($Project, $Credentials)

    Set-FireBrewingPhase 'Waiting for database server' $null
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ($Project.Config.engine -eq 'sqlserver') {
                Invoke-FireSqlServer $Project.Container $Credentials.password 'master' 'SELECT 1;' | Out-Null
            }
            else {
                Invoke-FirePostgres $Project.Container $Credentials.password 'postgres' 'SELECT 1;' | Out-Null
            }
            $ready = $true
            break
        }
        catch {
            if ($Script:FireBrewing) {
                for ($tick = 0; $tick -lt 16; $tick++) { Update-FireBrewing; Start-Sleep -Milliseconds 125 }
            }
            else { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $ready) { throw "Database server in '$($Project.Container)' did not become ready." }
}

function Get-FirePostgresDataMount {
    param([string]$Image)

    try { $volumesJson = Invoke-FireNative docker @('image', 'inspect', $Image, '--format', '{{json .Config.Volumes}}') }
    catch {
        Invoke-FireNative docker @('pull', $Image) -Activity 'Pulling PostgreSQL image' | Out-Null
        $volumesJson = Invoke-FireNative docker @('image', 'inspect', $Image, '--format', '{{json .Config.Volumes}}')
    }
    $volumes = $volumesJson | ConvertFrom-Json
    $targets = @($volumes.PSObject.Properties.Name | Where-Object { $_ -eq '/var/lib/postgresql' -or $_ -eq '/var/lib/postgresql/data' })
    if ($targets.Count -ne 1) { throw "Cannot determine PostgreSQL data mount for image '$Image'." }
    return $targets[0]
}

function Remove-FireSetupResources {
    param($Project)

    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        $container = Get-FireContainerJson $Project.Container
        $labels = if ($container) { $container.Config.Labels } else { $null }
        if ($labels -and $labels.PSObject.Properties['fire.managed'] -and $labels.PSObject.Properties['fire.project'] -and
            $labels.'fire.managed' -eq 'true' -and $labels.'fire.project' -eq $Project.Id) {
            Invoke-FireNative docker @('rm', '-f', $Project.Container) | Out-Null
        }
    }
    catch { $cleanupErrors.Add("Container '$($Project.Container)' cleanup failed: $($_.Exception.Message)") }
    try {
        $volume = Get-FireVolumeJson $Project.Volume
        $labels = if ($volume) { $volume.Labels } else { $null }
        if ($labels -and $labels.PSObject.Properties['fire.managed'] -and $labels.PSObject.Properties['fire.project'] -and
            $labels.'fire.managed' -eq 'true' -and $labels.'fire.project' -eq $Project.Id) {
            Invoke-FireNative docker @('volume', 'rm', $Project.Volume) | Out-Null
        }
    }
    catch { $cleanupErrors.Add("Volume '$($Project.Volume)' cleanup failed: $($_.Exception.Message)") }
    if ($cleanupErrors.Count) { throw "$($cleanupErrors -join ' ') Remove these resources with Docker Desktop before retrying setup." }
}

function Start-FireContainer {
    param($Project, $Credentials)

    Assert-FireDockerRunning
    Assert-FireEngineSupported $Project.Config.engine
    $container = Get-FireContainerJson $Project.Container
    if ($container) {
        Assert-FireOwnedContainer $Project $container
        if ($container.Config.Image -cne [string]$Project.Config.image) {
            throw "Container image differs from db/fire.json. Run 'fire remove' to replace this repository's container."
        }
        if (-not $container.State.Running) { Invoke-FireNative docker @('start', $Project.Container) | Out-Null }
        Wait-FireServer $Project $Credentials
        $running = Get-FireContainerJson $Project.Container
        $actualPort = Get-FirePort $Project $running
        if ($null -ne $Project.Config.port -and $actualPort -ne [int]$Project.Config.port) {
            throw "Container port $actualPort differs from db/fire.json port $($Project.Config.port). Remove this repository's FIRE container explicitly to change ports."
        }
        return $running
    }
    if (Get-FireVolumeJson $Project.Volume) {
        throw "Volume '$($Project.Volume)' exists without its container. FIRE will not overwrite it."
    }
    $labels = @('--label', 'fire.managed=true', '--label', "fire.project=$($Project.Id)")
    $internalPort = if ($Project.Config.engine -eq 'sqlserver') { 1433 } else { 5432 }
    $port = if ($null -eq $Project.Config.port) { '' } else { [string]$Project.Config.port }
    $mount = if ($Project.Config.engine -eq 'sqlserver') { '/var/opt/mssql' }
        else { Get-FirePostgresDataMount ([string]$Project.Config.image) }
    Invoke-FireNative docker (@('volume', 'create') + $labels + @($Project.Volume)) | Out-Null
    $envArgs = if ($Project.Config.engine -eq 'sqlserver') {
        @('--env', 'ACCEPT_EULA=Y', '--env', "MSSQL_SA_PASSWORD=$($Credentials.password)")
    }
    else { @('--env', "POSTGRES_PASSWORD=$($Credentials.password)") }
    try {
        $args = @('run', '--detach', '--name', $Project.Container) + $labels + $envArgs + @(
            '--publish', "127.0.0.1:${port}:$internalPort", '--volume', "$($Project.Volume):$mount", [string]$Project.Config.image)
        Invoke-FireNative docker $args -Activity 'Starting Docker' | Out-Null
        Get-FirePort $Project (Get-FireContainerJson $Project.Container) | Out-Null
        Wait-FireServer $Project $Credentials
        return Get-FireContainerJson $Project.Container
    }
    catch {
        $startupError = $_
        try { Remove-FireSetupResources $Project }
        catch { throw "$($startupError.Exception.Message) $($_.Exception.Message)" }
        throw $startupError
    }
}

function Test-FireDatabaseExists {
    param($Project, $Credentials, [string]$Name)

    if ($Project.Config.engine -eq 'sqlserver') {
        $result = Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "SELECT CASE WHEN DB_ID(N'$Name') IS NULL THEN 0 ELSE 1 END;"
    }
    else {
        $result = Invoke-FirePostgres $Project.Container $Credentials.password 'postgres' "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname='$Name') THEN 1 ELSE 0 END;"
    }
    return $result.Trim() -eq '1'
}

function New-FireDatabase {
    param($Project, $Credentials, [string]$Name)

    Assert-FireName $Name 'database name'
    if (Test-FireDatabaseExists $Project $Credentials $Name) { return }
    if ($Project.Config.engine -eq 'sqlserver') {
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "CREATE DATABASE [$Name];" -Activity "Creating $Name" | Out-Null
    }
    else {
        Invoke-FirePostgres $Project.Container $Credentials.password 'postgres' "CREATE DATABASE `"$Name`";" -Activity "Creating $Name" | Out-Null
    }
}

function Remove-FireDatabase {
    param($Project, $Credentials, [string]$Name)

    Assert-FireName $Name 'database name'
    if (-not (Test-FireDatabaseExists $Project $Credentials $Name)) { return }
    if ($Project.Config.engine -eq 'sqlserver') {
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Name];" | Out-Null
    }
    else {
        Invoke-FirePostgres $Project.Container $Credentials.password 'postgres' "DROP DATABASE `"$Name`" WITH (FORCE);" | Out-Null
    }
}

function Invoke-FireFlyway {
    param($Project, $Credentials, $Database, [string]$Command, [string]$ExtraPath, [switch]$SkipExecuting, [string]$Activity)

    $migrationOwner = if ($Database.PSObject.Properties['migrationOwner']) { $Database.migrationOwner } else { $Database.name }
    $migrationPath = Join-Path $Project.DbRoot "migrations/$migrationOwner"
    $url = if ($Project.Config.engine -eq 'sqlserver') {
        "jdbc:sqlserver://localhost:1433;databaseName=$($Database.name);encrypt=true;trustServerCertificate=true"
    }
    else { "jdbc:postgresql://localhost:5432/$($Database.name)" }
    $args = @('run', '--rm', '--network', "container:$($Project.Container)", '--volume', "${migrationPath}:/flyway/sql:ro")
    $locations = 'filesystem:/flyway/sql'
    if ($ExtraPath) {
        $args += @('--volume', "${ExtraPath}:/flyway/extra:ro")
        $locations += ',filesystem:/flyway/extra'
    }
    $work = $null
    try {
        $baseline = Join-Path $migrationPath 'V00001__Baseline.sql'
        $content = [IO.File]::ReadAllText($baseline)
        $name = if ($Project.Config.engine -eq 'sqlserver') { "[$migrationOwner]" } else { "`"$migrationOwner`"" }
        $declaration = [Regex]::new('\A(?<header>(?:[ \t]*(?:--[^\r\n]*)?\r?\n)*)[ \t]*(?i:CREATE[ \t]+DATABASE)[ \t]+' + [Regex]::Escape($name) + '[ \t]*;[ \t]*(?:\r?\n|\z)')
        if ($declaration.IsMatch($content)) {
            # FIRE creates Main, Shadow and verification DBs before replaying their schema.
            $work = New-FireWorkDirectory $Project 'flyway'
            $prepared = Join-Path $work 'V00001__Baseline.sql'
            [IO.File]::WriteAllText($prepared, $declaration.Replace($content, '${header}-- Database creation is handled by FIRE.' + "`nSELECT 1;`n", 1), [Text.UTF8Encoding]::new($false))
            $args += @('--volume', "${prepared}:/flyway/sql/V00001__Baseline.sql:ro")
        }
        $args += @('--env', "FLYWAY_PASSWORD=$($Credentials.password)", $Project.Config.flywayImage,
            "-url=$url", "-user=$($Credentials.user)", "-locations=$locations", '-connectRetries=12')
        if ($SkipExecuting) { $args += '-skipExecutingMigrations=true' }
        if ($Script:FireBrewing -and $Command -eq 'migrate' -and -not $SkipExecuting) {
            $args += '-X'
            $result = $Script:FireBrewing.Result
            $progress = [PSCustomObject]@{ Counts = @{}; Parsing = ''; InMigration = $false; Started = 0L; Migrations = 0; CurrentTotal = $null }
            $readProgress = Get-Command Read-FireMigrationProgress
            $outputLineAction = {
                param([string]$Line, [bool]$IsError)
                if ($Line.StartsWith('DEBUG: ', [StringComparison]::Ordinal) -or $Line.StartsWith('Successfully applied ', [StringComparison]::Ordinal)) {
                    & $readProgress $progress $result $Line
                }
                # SQL debug text and configuration stay out of retained error output.
                return $IsError -or $Line -match '^(?:ERROR|WARNING):'
            }.GetNewClosure()
            $args += $Command
            try { return (Invoke-FireNative docker $args -Activity $Activity -OutputLineAction $outputLineAction).Replace($Credentials.password, '[redacted]') }
            catch { throw $_.Exception.Message.Replace($Credentials.password, '[redacted]') }
        }
        $args += $Command
        return Invoke-FireNative docker $args -Activity $Activity
    }
    finally {
        if ($work) {
            if (Test-Path -LiteralPath $prepared) { Remove-Item -LiteralPath $prepared -Force }
            Remove-Item -LiteralPath $work -Force
        }
    }
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCDnhWwREs2+rdB
# aQqdkLRJVAbln+i/6iLyEv13D4HbxaCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIFAmmSll2P7lZ9Wz
# iGJqh5HGaDesVnfZYMp3pC5parDoMA0GCSqGSIb3DQEBAQUABIIBgD05xwIAwVKT
# qZCyW5D/VWP2EcWsIuBxi6MGz3iKqN/OZgVCZTkqerQ38ELxOjf/+/t790QMadSl
# /SyKKtEUh5eNL7RYbQ4+tBXlLpH0SX9r5pNwVtdiiqsJBVMuBcdO5FSaUxa4fWw4
# Gx3lah6oaypi1jATXfl2IyM0RNrFjLmwcgyEKQUK9B9Hixz7d+r6MNgOh1gIHXUW
# +xSEpatQAYQLuNzBIacLagHpjhoRFPdhBqL3fiDe/jgleokhFzuWUKQDk3byicdM
# wW0fJqOAhmdrzMA+T97iz/x6CtBxYQr42k7+SujB9JIl9PNhSX3xd4LotPwlqVQa
# rwpi++Fs8rc9/HmF58408sKWlY8FLAVr50hyGJ4+LMtBdefvqAVEBBBxBYuRCk4q
# UPFTTkrTxh/eP7BYLs4Cv01lvXCmgsQmCde9KhswuGzhAyWfy+XUeTIyazkt6lwq
# 1F+DvhSdJtPPcr1SXvP3zopMUaaGEu+xDQmVgL3FSpt6RmtXkimxyqGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjRaMC8GCSqGSIb3DQEJBDEiBCCK
# XSQwJ/t3OphZuS34lUoEI+xc5r9OpfkYscp9lnBIzDANBgkqhkiG9w0BAQEFAASC
# AgAm5J0a5fB/C/2pLe9Gk4ygEs1D3GC4SsAWTAYIfnTdkso1/hZ0gIcDiUC4QnLK
# 2JLuztHiN7IBW3NKZETQwMetXkzJV+zAo/nFewuWLBpTJ4PYZvpYgxq2VV+mPmVH
# UsBFk5J6HG0FAFizbfo3gdtLvqYjR657Jdfoo63MG/MleoTZuxamPZFo5hzlGYpv
# Uvi6QmcLU9jLbgie3mqFR7Jiv1UoMW/up0P6zXnEtOSHqaaYLtZpxTMy9e6AyiEd
# hS5+8TIzTyopROTXsQKfhHXDkFOsG3jkPqko1r2LL2FAmdR2d6/n66N4sgdUWnS5
# 5Qf5MMdnKhfEct2gaPArzY60/uP1xWBrMG7rzOiKr+fuKR1ah83u/yX6udibqt1+
# UnxKfF4MW1/mE+VbH63lB8YeYV4ws0eyayJ9viNqtZOPYFk4KRisuNTVd+Kb40DO
# hRA6jEuy0oDPH1E0iOH7luly+qiGpOGkt5H35R50cHVrilb9HmS/u00fCfsgkHcg
# TQL0wQJ1AJpac7bJk2YFyttSopqQWHqsm/6SvYRLBvhKdrwLNXxNdko/M20eq9Io
# d1lOj0sWrjVEZm87PXyblxEEzFIskQ3GOoyfJc8JKXJeLYY74iOscHZlolr42Jsp
# keRwLPI6TApepdWoqH15n1jIf0zUklb7kU5hVM/r6vf3LA==
# SIG # End signature block
