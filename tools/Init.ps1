function Get-FireMenuViewport {
    param([int]$Count, [int]$Current, [int]$Start, [int]$Height, [int]$FooterCount)

    $height = [Math]::Max(1, $Height)
    $showTitle = $height -ge 3
    $footerRows = [Math]::Min($FooterCount, $height - [int]$showTitle - 1)
    $visible = [Math]::Min($Count, $height - [int]$showTitle - $footerRows)
    $start = [Math]::Clamp($Start, 0, $Count - $visible)
    if ($Current -lt $start) { $start = $Current }
    elseif ($Current -ge $start + $visible) { $start = $Current - $visible + 1 }
    return [PSCustomObject]@{
        Start = $start; Count = $visible; ShowTitle = $showTitle; FooterCount = $footerRows
    }
}

function Format-FireMenuText {
    param([string]$Text, [int]$Width)

    $text = $Text.Replace("`r", ' ').Replace("`n", ' ')
    if ($text.Length -le $Width) { return $text }
    if ($Width -ge 3) { return $text.Substring(0, $Width - 3) + '...' }
    return $text.Substring(0, [Math]::Max(0, $Width))
}

function Read-FireChoice {
    param([string]$Title, [object[]]$Choices, [switch]$MultiSelect, [object[]]$SelectedValues = @(),
        [string[]]$Footer = @())

    if (-not $Choices.Count) { throw "No options available for '$Title'." }
    if ($Choices.Count -eq 1 -and -not $MultiSelect) { return $Choices[0].Value }
    $enabled = @($Choices | ForEach-Object { $_.Value -in $SelectedValues })

    if (-not (Test-FireTerminal -Interactive)) {
        for ($index = 0; $index -lt $Choices.Count; $index++) {
            $state = $(if ($MultiSelect) { if ($enabled[$index]) { ' (on)' } else { ' (off)' } } else { '' })
            Write-Host "$($index + 1). $($Choices[$index].Label)$state"
        }
        if ($MultiSelect) {
            $answer = (Read-Host "$Title (enabled numbers, comma separated; Enter keeps settings; 0 turns all off)").Trim()
            if (-not $answer) { return @($Choices | Where-Object { $_.Value -in $SelectedValues } | ForEach-Object { $_.Value }) }
            if ($answer -eq '0') { return @() }
            $numbers = @($answer.Split(',') | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
            foreach ($number in $numbers) {
                if ($number -notmatch '^[1-9][0-9]*$' -or [int]$number -gt $Choices.Count) { throw 'Choose numbers shown in the list.' }
            }
            return @($numbers | ForEach-Object { $Choices[[int]$_ - 1].Value })
        }
        $answer = (Read-Host "$Title (number)").Trim()
        if ($answer -notmatch '^[1-9][0-9]*$' -or [int]$answer -gt $Choices.Count) {
            throw 'Choose a number shown in the list.'
        }
        return $Choices[[int]$answer - 1].Value
    }

    $current = 0
    $selected = 0
    $start = 0
    $drawnRows = 0
    $lastWidth = 0
    $lastHeight = 0
    $redraw = $true
    if (-not $Footer.Count) {
        $instructions = if ($MultiSelect) { '↑↓ move  Space toggle  Enter save  Esc cancel' }
            else { '↑↓ move  Space select  Enter continue  Esc cancel' }
        $Footer = @('', $instructions)
    }
    $cursorVisible = $true
    if ($IsWindows) { $cursorVisible = [Console]::CursorVisible }

    [Console]::Write("`e[?25l")
    try {
        while ($true) {
            $width = [Math]::Max(0, [Console]::WindowWidth - 1)
            $height = [Console]::WindowHeight
            if ($redraw -or $width -ne $lastWidth -or $height -ne $lastHeight) {
                $viewport = Get-FireMenuViewport $Choices.Count $current $start $height $Footer.Count
                $start = $viewport.Start
                $lines = [Collections.Generic.List[string]]::new()
                if ($viewport.ShowTitle) {
                    $heading = $Title
                    if ($viewport.Count -lt $Choices.Count) { $heading += " ($($start + 1)-$($start + $viewport.Count) of $($Choices.Count))" }
                    $lines.Add((Format-FireOrange (Format-FireMenuText $heading $width)))
                }
                for ($index = $start; $index -lt $start + $viewport.Count; $index++) {
                    $pointer = if ($index -eq $current) { '›' } else { ' ' }
                    $isSelected = if ($MultiSelect) { $enabled[$index] } else { $index -eq $selected }
                    $marker = if ($isSelected) { Format-FireOrange '○' }
                        else { "$($PSStyle.Foreground.BrightBlack)○$($PSStyle.Reset)" }
                    $label = [string]$Choices[$index].Label
                    if (-not $viewport.ShowTitle) { $label = "$($index + 1)/$($Choices.Count) $label" }
                    if ($width -lt 4) { $lines.Add((Format-FireOrange (Format-FireMenuText "$pointer ○ " $width))) }
                    else {
                        $label = Format-FireMenuText $label ($width - 4)
                        $lines.Add((Format-FireOrange "$pointer ") + $marker + "$($PSStyle.Foreground.White) $label$($PSStyle.Reset)")
                    }
                }
                if ($viewport.FooterCount) {
                    foreach ($line in @($Footer | Select-Object -Last $viewport.FooterCount)) {
                        $lines.Add("$($PSStyle.Foreground.BrightBlack)$(Format-FireBrand (Format-FireMenuText $line $width))$($PSStyle.Reset)")
                    }
                }
                if ($drawnRows) {
                    $menuTop = [Math]::Max([Console]::WindowTop, [Console]::CursorTop - $drawnRows + 1)
                    $menuTop = [Math]::Clamp($menuTop, 0, [Console]::BufferHeight - 1)
                    [Console]::SetCursorPosition(0, $menuTop)
                }
                Write-Host ("`r`e[J" + ($lines -join "`r`n")) -NoNewline
                $drawnRows = $lines.Count
                $lastWidth = $width
                $lastHeight = $height
                $redraw = $false
            }
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 100; continue }
            $key = [Console]::ReadKey($true)
            $redraw = $true
            switch ($key.Key) {
                UpArrow { $current = ($current + $Choices.Count - 1) % $Choices.Count }
                DownArrow { $current = ($current + 1) % $Choices.Count }
                Spacebar { if ($MultiSelect) { $enabled[$current] = -not $enabled[$current] } else { $selected = $current } }
                Enter {
                    if ($MultiSelect) { return @(for ($index = 0; $index -lt $Choices.Count; $index++) { if ($enabled[$index]) { $Choices[$index].Value } }) }
                    return $Choices[$selected].Value
                }
                Escape { throw [OperationCanceledException]::new('Selection canceled.') }
            }
        }
    }
    finally {
        [Console]::WriteLine()
        if ($cursorVisible) { [Console]::Write("`e[?25h") }
    }
}

function Read-FireEngine {
    $choices = @(Get-FireSupportedEngines | ForEach-Object {
        [PSCustomObject]@{ Label = $(if ($_ -eq 'sqlserver') { 'SQL Server' } else { 'PostgreSQL' }); Value = $_ }
    })
    return Read-FireChoice 'Database engine' $choices
}

function Read-FireImage {
    param([string]$Label, [string]$Repository, [string]$TagPattern)

    $images = @(Get-FireLocalImages $Repository $TagPattern)
    if (-not $images.Count) {
        throw "No local $Label image found. Run 'fire install' to fetch the latest tools, then run 'fire init' again."
    }
    if ($images.Count -eq 1) {
        Write-FireText "Using local ${Label} image: $($images[0])"
        return $images[0]
    }
    $choices = @($images | ForEach-Object { [PSCustomObject]@{ Label = $_; Value = $_ } })
    return Read-FireChoice "$Label image" $choices
}

function Read-FireDatabaseNames {
    param([Parameter(Mandatory)][ValidateSet('sqlserver', 'postgresql')][string]$Engine)

    $names = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($true) {
        $name = (Read-Host 'Database name').Trim()
        if (-not $name) { Write-FireText 'Enter a database name.'; continue }
        Assert-FireDatabaseName $name $Engine
        if (-not $seen.Add($name)) { Write-FireText "Database '$name' was already added."; continue }
        $names.Add($name)
        $another = Read-FireChoice 'Add another database?' @(
            [PSCustomObject]@{ Label = 'No'; Value = $false },
            [PSCustomObject]@{ Label = 'Yes'; Value = $true }
        )
        if (-not $another) { break }
    }
    Write-FireText "Migration order: $($names -join ', ')"
    return @($names)
}

function Read-FireInitOptions {
    $engine = Read-FireEngine
    Assert-FireEngineSupported $engine
    $image = if ($engine -eq 'sqlserver') {
        Read-FireImage 'SQL Server' 'mcr.microsoft.com/mssql/server' '[0-9][A-Za-z0-9_.-]*'
    }
    else {
        Read-FireImage 'PostgreSQL' 'postgres' '[0-9][A-Za-z0-9_.-]*'
    }
    $flywayImage = Read-FireImage 'Flyway' 'flyway/flyway' '[0-9][A-Za-z0-9_.-]*'
    $portText = (Read-Host 'Host port (press Enter for an automatically assigned free port)').Trim()
    $port = $null
    if ($portText) {
        $portValue = 0
        if (-not [int]::TryParse($portText, [ref]$portValue) -or $portValue -lt 1 -or $portValue -gt 65535) {
            throw 'Host port must be 1-65535. Press Enter for automatic assignment.'
        }
        $port = $portValue
    }
    $containerName = (Read-Host 'Docker container name').Trim()
    if (-not $containerName) { throw 'Enter a Docker container name.' }
    Assert-FireContainerName $containerName
    $databases = @(Read-FireDatabaseNames $engine | ForEach-Object { [PSCustomObject]@{ name = $_; seedTables = @() } })
    return [PSCustomObject]@{ version = 1; engine = $engine; image = $image; flywayImage = $flywayImage; port = $port; containerName = $containerName; databases = @($databases) }
}

function Get-FireInitProject {
    param([string]$Root, $Config, [string]$Staging)

    $id = (Get-FireHash ([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant())).Substring(0, 16)
    return [PSCustomObject]@{
        Root = $Root
        DbRoot = $Staging
        LocalRoot = Join-Path $Root 'db/.fire'
        Config = $Config
        Id = $id
        Container = $Config.containerName
        Volume = "fire_${id}_data"
    }
}

function Initialize-FireProject {
    $root = Get-FireGitRoot
    if ([IO.Path]::GetFullPath((Get-Location).Path) -cne $root) {
        throw "Run 'fire init' at repository root '$root'."
    }
    $dbRoot = Join-Path $root 'db'
    $configPath = Join-Path $dbRoot 'fire.json'
    if (Test-Path -LiteralPath $configPath) { throw "FIRE config already exists: '$configPath'." }
    $config = Read-FireInitOptions
    New-Item -ItemType Directory -Path $dbRoot -Force | Out-Null
    $ignore = Join-Path $dbRoot '.gitignore'
    $ignoreContent = if (Test-Path -LiteralPath $ignore) { [IO.File]::ReadAllText($ignore) } else { '' }
    if ($ignoreContent -notmatch '(?m)^\.fire/?\r?$') {
        if ($ignoreContent -and -not $ignoreContent.EndsWith("`n")) { $ignoreContent += "`n" }
        [IO.File]::WriteAllText($ignore, $ignoreContent + ".fire/`n", [Text.UTF8Encoding]::new($false))
    }
    $staging = Join-Path $dbRoot ".fire/init_$([Guid]::NewGuid().ToString('N'))"
    $project = Get-FireInitProject $root $config $staging
    if (Get-FireContainerJson $project.Container) { throw "Container '$($project.Container)' already exists. Resolve it before init." }
    $success = $false
    $initFailureMessage = $null
    $published = [Collections.Generic.List[string]]::new()
    try {
        foreach ($database in @($config.databases)) {
            $migrationDir = Join-Path $staging "migrations/$($database.name)"
            New-Item -ItemType Directory -Path $migrationDir -Force | Out-Null
            $baseline = Join-Path $migrationDir 'V00001__Baseline.sql'
            $name = if ($config.engine -eq 'sqlserver') { "[$($database.name)]" } else { "`"$($database.name)`"" }
            [IO.File]::WriteAllText($baseline, "-- Add your schema here.`nCREATE DATABASE $name;`n", [Text.UTF8Encoding]::new($false))
        }
        Get-FireCredentials $project -Create | Out-Null
        $stagedConfig = Join-Path $staging 'fire.json'
        [IO.File]::WriteAllText($stagedConfig, ($config | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        foreach ($database in @($config.databases)) {
            $destination = Join-Path $dbRoot "migrations/$($database.name)"
            if (Test-Path -LiteralPath $destination) { throw "Migration destination already exists: '$destination'." }
        }
        foreach ($database in @($config.databases)) {
            $source = Join-Path $staging "migrations/$($database.name)"
            $destination = Join-Path $dbRoot "migrations/$($database.name)"
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Move-Item -LiteralPath $source -Destination $destination
            $published.Add($destination)
        }
        [IO.File]::Move($stagedConfig, $configPath)
        $success = $true
        Write-FireText "FIRE project initialized at $dbRoot"
        Write-FireText "Docker container: $($config.containerName)"
        foreach ($database in @($config.databases)) {
            Write-FireText "Ready for fire up. To use an existing schema, replace the create statement in db/migrations/$($database.name)/V00001__Baseline.sql with your schema."
        }
    }
    catch {
        $initFailureMessage = $_.Exception.Message
        if ($success) { throw }
        $failure = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        $allowed = [IO.Path]::GetFullPath((Join-Path $dbRoot 'migrations')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($destination in $published) {
            try {
                $resolved = [IO.Path]::GetFullPath($destination)
                if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected init rollback path.' }
                Move-Item -LiteralPath $resolved -Destination (Join-Path $staging "migrations/$(Split-Path -Leaf $resolved)")
            }
            catch { $rollbackErrors.Add("'$destination': $($_.Exception.Message)") }
        }
        if ($rollbackErrors.Count) {
            $initFailureMessage = "$($failure.Exception.Message) Init rollback failed for $($rollbackErrors -join '; '). Review those folders before retrying fire init."
            throw $initFailureMessage
        }
        throw $failure
    }
    finally {
        try {
            if (Test-Path -LiteralPath $staging) {
                $allowed = [IO.Path]::GetFullPath($project.LocalRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                $resolved = [IO.Path]::GetFullPath($staging)
                if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected init cleanup path.' }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
        catch {
            $message = "Init staging folder '$staging' cleanup failed: $($_.Exception.Message) Remove this folder before retrying fire init."
            if ($initFailureMessage) { $message = "$initFailureMessage $message" }
            throw $message
        }
    }
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBs20WhMiciB00N
# nqreaYqDwC1u2HpAr0mUA9t+Bv+Rf6CCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIxqpAbpFvKb70ER
# eHE5JHdoIjLj4UUCk75M6R0VsCHUMA0GCSqGSIb3DQEBAQUABIIBgLyHV1EoDnew
# Ghlo6UktTqVAVZrr68xT7OvLCzAGJU1gvOv4OFs4CSFlMUcDPQ5/0Jy+06/7xzkW
# Vdch5NF2wpIcMElFK1L68i8DURANtR2t9PBNCRiAzdqv/LlJJgl7sYdVPBXMEeyy
# ilbQwO62TgCVqEcXXZDHKtKduOugmp8GXbFJOfcCdJZKnXNyjPiXntkjNO/oVmWV
# 6Lt+q7LVTApOR9DlEOf38Ta1w0/1qAKt0Ar8lLivdHWwUiLKZriMj7aT9mdL9Fvl
# 6kvxufG7YpDt3df2BDbZ042S6+LW79zmLS2vlmdSJKixF7U0ulwrFdk0wM47R8zB
# R3tQ+Z93aAjRBWswUBtTTAX7h2enh5DngI5CtFKX3rkyNngIlV1PtujarO6wrq1q
# IeQW7fZAu9pSmfxrAtSvBYC0qHuKDJyWtSDVi1vjCQl3RTvRSqTYRMF7oOQs0/RQ
# g/sEx3Kl/xgIznwyCq+cjGW1MSU0K1SG0QcR5EMd78WuzXijF9DQo6GCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjRaMC8GCSqGSIb3DQEJBDEiBCBK
# M+ev0YKDwvKri+WEBbx/MN5v5hfvj635M15PMFe2aDANBgkqhkiG9w0BAQEFAASC
# AgAqTBKZxT1qewW75RcKApND/rO9Ue4KZpTT9mWrupfoW9Z8TMx5J3tAyDPbPu06
# qTyW0JkvGUjjbW2xpy7rFXFLzrTNoqSpBfcthDkx90BIjS1oG2OvdLFfesDIuQ0b
# rj0By6iITfIrXPfwnExqqM5FdIWEMRY7ZKRhCqhBnon2snDnZE3fIn4p19OFRIvI
# mcelN8bWfcvqWKVTtOU8nxVOe6J7zugsibV81i20shWxWiFJEzKYqBWNd+H+9J4M
# qOFdKpFidtRRARE2s0VedJkHSatqqZbaQZ+1kyilxCD4BYJ0jQGInTtuVGoH5NFo
# OqDPlECUwdW8wAjtNfKgBUgP+1f7yZ8y2AeMfFxTW+sRh7EUG4VejFtxUI8SJyno
# ZpKP4fhIHeEN3pSiGTT7b+j1gyR6taGrLQAn8UmG+NpCaTPtEyvhOawZhD6as1MV
# G/TfXDXSfSY6PzY0UgQ+48YxCxMVtsdDcIFRaYLsKwuuQGNeyiyyXOp8F2hV7591
# 91S3cnfuUexGUzGze0JY+i/6d18t/1yjC47VgZorD+9u+uyNa8c91wufs1vOilnj
# ZAKvqQ2ZpTXt4hES0T0OzBC8pjxfatnwazbGncbciCHfGyLe3pXDN4maW5xPjviT
# lhajRqlav6i7OZXfA2c4M6uOZBKFDW5TBNLD6YhWaeSrnA==
# SIG # End signature block
