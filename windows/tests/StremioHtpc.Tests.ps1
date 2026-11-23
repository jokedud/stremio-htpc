BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\StremioHtpc.psm1') -Force
    $script:Key = [Convert]::ToBase64String([byte[]](1..32))
    function New-Tunnel([string]$Name, [string]$Body) {
        $path = Join-Path $TestDrive "$Name.conf"
        Set-Content -LiteralPath $path -Value $Body
        $path
    }
}

Describe 'Merge-StremioServerSettings' {
    It 'keeps unrelated keys and backs up once' {
        $path = Join-Path $TestDrive 'server-settings.json'
        Set-Content $path '{"cacheSize":1,"keep":"yes"}'
        Merge-StremioServerSettings $path
        Set-Content $path '{"cacheSize":2}'
        Merge-StremioServerSettings $path
        $settings = Get-Content $path -Raw | ConvertFrom-Json
        $settings.cacheSize | Should -Be 21474836480
        $settings.transcodeHardwareAccel | Should -BeTrue
        (Get-Content "$TestDrive\server-settings.json.pre-htpc" -Raw | ConvertFrom-Json).keep | Should -Be 'yes'
    }

    It 'creates missing files' {
        $path = Join-Path $TestDrive 'new\server-settings.json'
        Merge-StremioServerSettings $path
        (Get-Content $path -Raw | ConvertFrom-Json).cacheSize | Should -Be 21474836480
    }

    It 'refuses malformed or non-object JSON without clobbering it' {
        foreach ($body in '{broken', '[1,2]') {
            $path = Join-Path $TestDrive 'bad.json'
            Set-Content $path $body -NoNewline
            { Merge-StremioServerSettings $path } | Should -Throw
            Get-Content $path -Raw | Should -Be $body
        }
    }
}

Describe 'Read-HtpcAddonUrls' {
    It 'merges and deduplicates addon files' {
        $dir = Join-Path $TestDrive 'addons'
        New-Item -ItemType Directory $dir | Out-Null
        Set-Content "$dir\addons.txt" "https://a.example/manifest.json`nhttps://b.example/x/manifest.json"
        Set-Content "$dir\addons.local" 'https://a.example/manifest.json https://c.example/manifest.json'
        Read-HtpcAddonUrls $dir | Should -Be @('https://a.example/manifest.json', 'https://b.example/x/manifest.json', 'https://c.example/manifest.json')
    }

    It 'rejects non-HTTPS or non-manifest URLs' {
        $dir = Join-Path $TestDrive 'bad-addons'
        New-Item -ItemType Directory $dir | Out-Null
        foreach ($url in 'http://a.example/manifest.json', 'https://a.example/other.json') {
            Set-Content "$dir\addons.txt" $url
            { Read-HtpcAddonUrls $dir } | Should -Throw 'Addon URLs must be HTTPS manifest.json URLs'
        }
    }

    It 'validates the shipped defaults' {
        $dir = Join-Path $TestDrive 'defaults'
        New-Item -ItemType Directory $dir | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..\..\addons.txt') $dir
        (Read-HtpcAddonUrls $dir).Count | Should -BeGreaterThan 0
    }
}

Describe 'Test-WireGuardConfig' {
    It 'accepts a split tunnel' {
        $path = New-Tunnel 'home' "[Interface]`nPrivateKey = $Key`nAddress = 10.0.0.2/32`n`n[Peer]`nPublicKey = $Key`nAllowedIPs = 10.0.0.0/24`nEndpoint = vpn.example:51820"
        $tunnel = Test-WireGuardConfig $path
        $tunnel.Name | Should -Be 'home'
        $tunnel.FullTunnel | Should -BeFalse
        $tunnel.Service | Should -Be 'WireGuardTunnel$home'
    }

    It 'flags full tunnels' {
        $path = New-Tunnel 'full' "[Interface]`nPrivateKey = $Key`nAddress = 10.0.0.2/32`n[Peer]`nPublicKey = $Key`nAllowedIPs = 10.0.0.0/24, ::/0`nEndpoint = vpn.example:51820"
        (Test-WireGuardConfig $path).FullTunnel | Should -BeTrue
    }

    It 'rejects <case>' -ForEach @(
        @{ case = 'a missing peer'; name = 'nopeer'; body = "[Interface]`nPrivateKey = KEY`nAddress = 10.0.0.2/32"; error = '*needs a `[Peer`]*' }
        @{ case = 'a missing endpoint'; name = 'noend'; body = "[Interface]`nPrivateKey = KEY`nAddress = 10.0.0.2/32`n[Peer]`nPublicKey = KEY`nAllowedIPs = 0.0.0.0/0"; error = '*needs endpoint*' }
        @{ case = 'an invalid key'; name = 'badkey'; body = "[Interface]`nPrivateKey = nope`nAddress = 10.0.0.2/32"; error = '*not a valid key*' }
        @{ case = 'an unsafe tunnel name'; name = 'bad name!'; body = '[Interface]'; error = '*file name*' }
        @{ case = 'an unknown section'; name = 'section'; body = '[Wat]'; error = '*Unknown WireGuard section*' }
    ) {
        $path = New-Tunnel $name ($body -creplace 'KEY', $Key)
        { Test-WireGuardConfig $path } | Should -Throw -ExpectedMessage $error
    }
}

Describe 'Sync-StremioAddons' {
    BeforeEach {
        $script:Calls = [Collections.Generic.List[object]]::new()
        $script:Manifest = [pscustomobject]@{ id = 'x'; version = '1'; name = 'X'; resources = @(); types = @(); catalogs = @() }
        Mock -ModuleName StremioHtpc Invoke-StremioJson {
            $script:Calls.Add([pscustomobject]@{ Uri = $Uri; Body = $Body })
            switch -Wildcard ($Uri) {
                '*/login' { [pscustomobject]@{ result = [pscustomobject]@{ authKey = 'auth' } } }
                '*/addonCollectionGet' { [pscustomobject]@{ result = [pscustomobject]@{ addons = @([pscustomobject]@{ transportUrl = 'https://old.example/manifest.json' }) } } }
                '*/manifest.json' { $script:Manifest }
                default { [pscustomobject]@{ result = [pscustomobject]@{ success = $true } } }
            }
        }
        $script:Password = ConvertTo-SecureString 'pw' -AsPlainText -Force
    }

    It 'appends only missing addons and logs out' {
        Sync-StremioAddons -Urls 'https://old.example/manifest.json', 'https://new.example/manifest.json' -Email 'a@b.c' -Password $Password
        $set = $Calls | Where-Object Uri -Like '*/addonCollectionSet'
        $set.Body.addons.transportUrl | Should -Be @('https://old.example/manifest.json', 'https://new.example/manifest.json')
        ($Calls | Where-Object Uri -Like '*/login').Body.password | Should -Be 'pw'
        $Calls[-1].Uri | Should -BeLike '*/logout'
    }

    It 'leaves the collection unchanged when a manifest is invalid' {
        $script:Manifest = [pscustomobject]@{ id = 'x' }
        { Sync-StremioAddons -Urls 'https://new.example/manifest.json' -Email 'a@b.c' -Password $Password } | Should -Throw '*unchanged*'
        $Calls.Uri | Should -Not -Contain 'https://api.strem.io/api/addonCollectionSet'
        $Calls[-1].Uri | Should -BeLike '*/logout'
    }

    It 'stops when the API returns an error' {
        Mock -ModuleName StremioHtpc Invoke-StremioJson { [pscustomobject]@{ error = [pscustomobject]@{ message = 'User not found' } } }
        { Sync-StremioAddons -Email 'a@b.c' -Password $Password } | Should -Throw 'Stremio API rejected login'
    }
}

Describe 'Test-HtpcDownload' {
    It 'rejects checksum mismatches' {
        $path = Join-Path $TestDrive 'file.bin'
        Set-Content $path 'data'
        { Test-HtpcDownload $path -Sha256 ('0' * 64) } | Should -Throw 'Checksum mismatch*'
        { Test-HtpcDownload $path -Sha256 (Get-FileHash $path).Hash } | Should -Not -Throw
    }

    It 'rejects unsigned files when a signer is required' {
        $path = Join-Path $TestDrive 'unsigned.ps1'
        Set-Content $path 'echo 1'
        { Test-HtpcDownload $path -Signer 'WireGuard LLC' } | Should -Throw 'Untrusted signature*'
    }
}
