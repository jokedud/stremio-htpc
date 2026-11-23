Set-StrictMode -Version Latest

$script:ApiBase = 'https://api.strem.io/api/'
$script:TunnelNamePattern = '^[a-zA-Z0-9_=+.-]{1,32}$'

function Merge-StremioServerSettings {
    <# Merge cache/acceleration settings without replacing unrelated keys. #>
    param([Parameter(Mandatory)][string]$Path)
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = [IO.File]::ReadAllText($Path)
        try { $parsed = $raw | ConvertFrom-Json } catch { throw 'Settings must be valid JSON' }
        if ($parsed -isnot [Management.Automation.PSCustomObject]) { throw 'Settings must be a JSON object' }
        foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        $backup = [IO.Path]::ChangeExtension($Path, '.json.pre-htpc')
        if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllText($backup, $raw) }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    }
    $settings['cacheSize'] = [int64]20 * 1GB
    $settings['transcodeHardwareAccel'] = $true
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, (($settings | ConvertTo-Json -Depth 20) + "`n"))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-HtpcAddonUrls {
    param([Parameter(Mandatory)][string]$ConfigDir)
    $urls = foreach ($name in 'addons.txt', 'addons.local') {
        $path = Join-Path $ConfigDir $name
        if (Test-Path -LiteralPath $path) { (Get-Content -LiteralPath $path -Raw) -split '\s+' | Where-Object { $_ } }
    }
    $unique = [Collections.Generic.List[string]]::new()
    foreach ($url in @($urls)) {
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
            -not $uri.Host -or -not $uri.AbsolutePath.EndsWith('/manifest.json')) {
            throw 'Addon URLs must be HTTPS manifest.json URLs'
        }
        if (-not $unique.Contains($url)) { $unique.Add($url) }
    }
    $unique.ToArray()
}

function Add-HtpcLocalAddons {
    param([Parameter(Mandatory)][string]$ConfigDir, [string]$Urls)
    $path = Join-Path $ConfigDir 'addons.local'
    $existing = if (Test-Path -LiteralPath $path) { (Get-Content -LiteralPath $path -Raw) -split '\s+' } else { @() }
    $merged = @(@($existing) + @($Urls -split '\s+') | Where-Object { $_ } | Select-Object -Unique)
    [IO.File]::WriteAllText($path, (($merged -join "`n") + "`n"))
    Protect-HtpcPath $path
}

function Invoke-StremioJson {
    param([Parameter(Mandatory)][string]$Uri, $Body)
    $params = @{ Uri = $Uri; UserAgent = 'stremio-htpc/1'; TimeoutSec = 40; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $params.Method = 'Post'
        $params.ContentType = 'application/json'
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress))
    }
    Invoke-RestMethod @params
}

function Invoke-StremioApi {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)]$Payload)
    $result = Invoke-StremioJson -Uri ($script:ApiBase + $Method) -Body $Payload
    if ($result -isnot [Management.Automation.PSCustomObject] -or $result.PSObject.Properties.Name -contains 'error' -or
        $result.PSObject.Properties.Name -notcontains 'result') {
        throw "Stremio API rejected $Method"
    }
    $result.result
}

function Sync-StremioAddons {
    <# Append missing manifests to the account collection; any failure leaves it unchanged. #>
    param([string[]]$Urls = @(), [Parameter(Mandatory)][string]$Email, [Parameter(Mandatory)][securestring]$Password)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $auth = Invoke-StremioApi 'login' @{ type = 'Login'; email = $Email; password = $plain; facebook = $false }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
    }
    $key = $auth.authKey
    try {
        $collection = Invoke-StremioApi 'addonCollectionGet' @{ type = 'AddonCollectionGet'; authKey = $key; update = $true }
        if ($null -eq $collection.addons) { throw 'Invalid addon collection' }
        $addons = [Collections.Generic.List[object]]::new()
        foreach ($addon in @($collection.addons)) { $addons.Add($addon) }
        $known = [Collections.Generic.HashSet[string]]::new()
        foreach ($addon in $addons) { [void]$known.Add([string]$addon.transportUrl) }
        foreach ($url in $Urls) {
            if ($known.Contains($url)) { continue }
            $manifest = Invoke-StremioJson -Uri $url
            $names = if ($manifest -is [Management.Automation.PSCustomObject]) { $manifest.PSObject.Properties.Name } else { @() }
            foreach ($required in 'id', 'version', 'name', 'resources', 'types', 'catalogs') {
                if ($names -notcontains $required) { throw 'Invalid addon manifest; collection left unchanged' }
            }
            $addons.Add([pscustomobject]@{ transportUrl = $url; manifest = $manifest
                    flags = [pscustomobject]@{ official = $false; protected = $false } })
            [void]$known.Add($url)
        }
        [void](Invoke-StremioApi 'addonCollectionSet' @{ type = 'AddonCollectionSet'; authKey = $key; addons = $addons.ToArray() })
    } finally {
        try { [void](Invoke-StremioApi 'logout' @{ type = 'Logout'; authKey = $key }) } catch { Write-Verbose 'Stremio logout failed' }
    }
}

function Test-WireGuardConfig {
    <# Validate a wg-quick style tunnel file; returns its tunnel name and whether it routes all traffic. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'WireGuard config not found' }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ([IO.Path]::GetExtension($Path) -ne '.conf') { throw 'WireGuard config must be a .conf file' }
    if ($name -notmatch $script:TunnelNamePattern) { throw 'WireGuard file name must be 1-32 characters of letters, digits, _ = + . -' }
    $section = $null
    $interface = @{}
    $peers = [Collections.Generic.List[hashtable]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $line = ($line -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^\[(\w+)\]$') {
            $section = $Matches[1].ToLowerInvariant()
            if ($section -eq 'peer') { $peers.Add(@{}) } elseif ($section -ne 'interface') { throw "Unknown WireGuard section [$($Matches[1])]" }
            continue
        }
        if ($line -notmatch '^([A-Za-z]+)\s*=\s*(.+)$') { throw 'Malformed WireGuard config line' }
        $target = switch ($section) { 'interface' { $interface } 'peer' { $peers[$peers.Count - 1] } default { throw 'WireGuard setting outside a section' } }
        $target[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim()
    }
    foreach ($field in 'privatekey', 'address') { if (-not $interface[$field]) { throw "WireGuard [Interface] needs $field" } }
    if ($interface.privatekey -notmatch '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$') { throw 'WireGuard PrivateKey is not a valid key' }
    if ($peers.Count -eq 0) { throw 'WireGuard config needs a [Peer]' }
    $fullTunnel = $false
    foreach ($peer in $peers) {
        foreach ($field in 'publickey', 'allowedips', 'endpoint') { if (-not $peer[$field]) { throw "WireGuard [Peer] needs $field" } }
        $routes = $peer.allowedips -split '\s*,\s*'
        if ($routes -contains '0.0.0.0/0' -or $routes -contains '::/0') { $fullTunnel = $true }
    }
    [pscustomobject]@{ Name = $name; FullTunnel = $fullTunnel; Service = "WireGuardTunnel`$$name" }
}

function Protect-HtpcPath {
    <# Restrict a file or directory to SYSTEM and Administrators. #>
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    $inherit = if ($isDir) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $identity = New-Object Security.Principal.SecurityIdentifier $sid
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $identity, 'FullControl', $inherit, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-HtpcDownload {
    param([Parameter(Mandatory)][string]$Path, [string]$Signer, [string]$Sha256)
    if ($Sha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256.ToUpperInvariant()) {
        throw "Checksum mismatch for $Path"
    }
    if ($Signer) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch "(^|, )CN=$([regex]::Escape($Signer))(,|$)") {
            throw "Untrusted signature on $Path"
        }
    }
}

if (-not ('HtpcLsa' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'HtpcLsa.cs') }

$script:Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$script:WinlogonValues = 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount', 'ForceAutoLogon'
$script:LsaBackup = 'L$stremio-htpc-DefaultPassword'
$script:LsaRegistryBackup = 'L$stremio-htpc-RegistryDefaultPassword'

function Backup-HtpcAutoLogon {
    <# Returns the previous Winlogon values; previous passwords are kept only in LSA private data. #>
    $values = Get-ItemProperty -LiteralPath $script:Winlogon
    $names = $values.PSObject.Properties.Name
    $backup = [ordered]@{}
    foreach ($name in $script:WinlogonValues) { $backup[$name] = if ($names -contains $name) { [string]$values.$name } else { $null } }
    $previous = [HtpcLsa]::Retrieve('DefaultPassword')
    if ($null -ne $previous) { [HtpcLsa]::Store($script:LsaBackup, $previous) }
    $backup['HadLsaPassword'] = $null -ne $previous
    $backup['HadRegistryPassword'] = $names -contains 'DefaultPassword'
    if ($backup['HadRegistryPassword']) { [HtpcLsa]::Store($script:LsaRegistryBackup, [string]$values.DefaultPassword) }
    $backup
}

function Set-HtpcAutoLogon {
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][securestring]$Password)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try { [HtpcLsa]::Store('DefaultPassword', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    Remove-ItemProperty -LiteralPath $script:Winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $script:Winlogon -Name DefaultUserName -Value $UserName
    Set-ItemProperty -LiteralPath $script:Winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
    Set-ItemProperty -LiteralPath $script:Winlogon -Name AutoAdminLogon -Value '1'
}

function Restore-HtpcAutoLogon {
    param([Parameter(Mandatory)]$Backup)
    foreach ($name in $script:WinlogonValues) {
        $value = $Backup.$name
        if ($null -eq $value) { Remove-ItemProperty -LiteralPath $script:Winlogon -Name $name -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -LiteralPath $script:Winlogon -Name $name -Value $value }
    }
    if ($Backup.HadLsaPassword) { [HtpcLsa]::Store('DefaultPassword', [HtpcLsa]::Retrieve($script:LsaBackup)) }
    else { [HtpcLsa]::Store('DefaultPassword', $null) }
    if ($Backup.HadRegistryPassword) {
        Set-ItemProperty -LiteralPath $script:Winlogon -Name DefaultPassword -Value ([HtpcLsa]::Retrieve($script:LsaRegistryBackup))
    }
    [HtpcLsa]::Store($script:LsaBackup, $null)
    [HtpcLsa]::Store($script:LsaRegistryBackup, $null)
}

$script:PowerSettings = @(
    @{ Sub = 'SUB_VIDEO'; Setting = 'VIDEOIDLE' },
    @{ Sub = 'SUB_SLEEP'; Setting = 'STANDBYIDLE' },
    @{ Sub = 'SUB_SLEEP'; Setting = 'HIBERNATEIDLE' }
)

function Get-HtpcPowerIndex {
    param([string]$Sub, [string]$Setting)
    $output = powercfg /query SCHEME_CURRENT $Sub $Setting 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $hex = @([regex]::Matches(($output -join "`n"), '0x[0-9a-fA-F]{8}') | ForEach-Object Value)
    if ($hex.Count -lt 2) { return $null }
    [Convert]::ToInt64($hex[$hex.Count - 2], 16)
}

function Set-HtpcPowerIndexes {
    <# Applies AC timeouts (missing entries mean "never") and returns the previous ones. #>
    param([hashtable]$Values = @{})
    $previous = @{}
    foreach ($item in $script:PowerSettings) {
        $key = "$($item.Sub)/$($item.Setting)"
        $current = Get-HtpcPowerIndex $item.Sub $item.Setting
        if ($null -eq $current) { continue }
        $previous[$key] = $current
        $target = if ($Values.ContainsKey($key)) { $Values[$key] } else { 0 }
        powercfg /setacvalueindex SCHEME_CURRENT $item.Sub $item.Setting $target | Out-Null
    }
    powercfg /setactive SCHEME_CURRENT | Out-Null
    $previous
}

Export-ModuleMember -Function Merge-StremioServerSettings, Read-HtpcAddonUrls, Add-HtpcLocalAddons, Invoke-StremioJson,
    Invoke-StremioApi, Sync-StremioAddons, Test-WireGuardConfig, Protect-HtpcPath, Test-HtpcDownload,
    Backup-HtpcAutoLogon, Set-HtpcAutoLogon, Restore-HtpcAutoLogon, Get-HtpcPowerIndex, Set-HtpcPowerIndexes
