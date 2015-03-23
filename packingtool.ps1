


function unpackFromHTTPZip {
    Param(
        [String] $url,
        [ValidateScript({Test-Path $_ -PathType "Container"})]
        [String] $dest
    )
    $dest = (Resolve-Path $dest).Path

    Write-Verbose "Clean folder $dest"
    del -Path $dest -Recurse > $null
    mkdir $dest > $null


    Write-Verbose "Downloading file $url"
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = "HEAD"
    $response = $req.GetResponse()
    $destFile = Split-Path $response.ResponseUri.LocalPath -Leaf
    $response.Close()
    
    if (-not $destFile) {
        $destFile = "src-file-pack.zip"
    }
    $destFile = Join-Path $dest $destFile

    wget $url -OutFile $destFile
    
    Write-Verbose "Unzipping file $destFile"

    if ($destFile.EndsWith("zip")) {
        $shell = new-object -ComObject shell.application
        $zip = $shell.NameSpace($destFile)
        $destFolder = $shell.NameSpace($dest)
        $zip.items() | % {$destFolder.copyhere($_);}
    } else {
        # using 7-zip
        Write-Verbose "Using 7-Zip to extract package"
        $7za = Join-Path $PSScriptRoot "7zip/7za.exe"
        
        if ($destFile.endswith('.tar.gz') -or $destFile.endswith('.tgz')) {
            $par = "/c $7za x `"$destFile`" -so | $7za x -aoa -si -ttar -o`"$dest`""
            Write-Verbose "cmd $par"
            $log = cmd $par 2>&1

        } else {
            Write-Verbose 
            $log = &$7za x "$destFile" -y -o"$dest" 2>&1
        }

        if (-not $log.Contains("Everything is Ok")) {
            Write-Error "Unzip file failed"
        }
    }

    Write-Verbose "Clean up unzipped path"
    del $destFile
}


function getInstalledVSEnvs {
    Get-ChildItem Env:\VS*COMNTOOLS | ? {Test-Path $_.value} `
    | select name, @{Name="value"; Expression={Join-Path (get-item $_.value).parent.parent.FullName "vc\vcvarsall.bat" }} `
    | ? {Test-Path $_.value} | % {New-Object psobject -Property @{name=$_.Name.Substring(0, 5); command=$_.Value}}
}


function executeWithVSEnv {
    Param(
        [Parameter(ValueFromPipeline=$True)] $vsenv,
        [String] $cmd,
        [ValidateSet("x86", "amd64")]
        [String] $arch = "amd64"
    )
    begin {
        $cmdargs = $cmd.split();
        Write-Verbose "Executing command $cmd under arch $arch with following environments"
    }
    process
    {
        Write-Verbose "Use environment $vsenv"
        
        &"$PSScriptRoot\cmdenv.cmd" $vsenv.command $arch @cmdargs
        if (-not $?) {
            Write-Error "Execute command $cmd failed under arch: $arch and env: $($vsenv.name)"
        }
    }
}

