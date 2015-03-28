


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
    $cmakeGenerators = @{
        "VS100COMNTOOLS" = "Visual Studio 10 2010";
        "VS110COMNTOOLS" = "Visual Studio 11 2012";
        "VS120COMNTOOLS" = "Visual Studio 12 2013";
        "VS140COMNTOOLS" = "Visual Studio 10 2015"}

    Get-ChildItem Env:\VS*COMNTOOLS | ? {Test-Path $_.value} `
    | select name, @{Name="value"; Expression={Join-Path (get-item $_.value).parent.parent.FullName "vc\vcvarsall.bat" }} `
    | ? {Test-Path $_.value} | % {New-Object psobject -Property @{name=$_.Name.Substring(0, 5); command=$_.Value; cmakeName=$cmakeGenerators[$_.Name]}}
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


function cmakeWithVSEnv {
    Param(
        [Parameter(ValueFromPipeline=$True)] $vsenv,
        [ValidateScript({Test-Path $_ -PathType "Container"})]
        [String] $srcPath,
        [ValidateScript({Test-Path $_ -PathType "Container"})]
        [String] $buildPath,
        [ValidateSet("Win32", "Win64")]
        [String[]] $archs = @("Win32", "Win64")
    )
    begin {
        $buildPath = (Resolve-Path $buildPath).Path
        $srcPath = (Resolve-Path $srcPath).Path
    }

    process
    {
        $subPath = Join-Path $buildPath $vsenv.name

        if ($archs -contains "Win32") {
            $tarPath = Join-Path $subPath "Win32"
            mkdir -Force $tarPath > $null
            pushd $tarPath
            cmake -G $vsenv.cmakeName $srcPath > cmakelog.log
            popd
            Write-Output $tarPath
        }

        if ($archs -contains "Win64") {
            Write-Verbose ""
            $tarPath = Join-Path $subPath "Win64"
            mkdir -Force $tarPath > $null
            pushd $tarPath
            cmake -G "$($vsenv.cmakeName) Win64" $srcPath > cmakelog.log
            popd
            Write-Output $tarPath

        }
    }

}

Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace nugetpackagepathfactory
{
	public class Folder
	{
		protected string m_path;

		protected string extpends(string folderName)
		{
			return Path.Combine(m_path, folderName);
		}

		public string path
		{
			get { return m_path; }
		}

		public Folder create()
		{
			if (!Directory.Exists(this.path))
				Directory.CreateDirectory(this.path);
			return this;
		}

		public override string ToString()
		{
			return path;
		}
	}

	public class DestFolder : Folder
	{
		public DestFolder(String path) { m_path = path; }
		public DestFolder name(string subFolderName)
		{
			return new DestFolder(this.extpends(subFolderName));
		}

		private string[] resolve(string srcPath, SearchOption opt)
		{
			string pathOnly = Path.GetDirectoryName(srcPath);
			if (pathOnly == String.Empty)
				pathOnly = ".";
			return Directory.GetFiles(pathOnly, Path.GetFileName(srcPath), opt);
		}

		public DestFolder copyTo(string srcPath, bool recursive = false)
		{
			create();
			foreach (var file in resolve(srcPath, recursive ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly))
				File.Copy(file, Path.Combine(this.path, Path.GetFileName(file)), true);
			return this;
		}

		public DestFolder moveTo(string srcPath, bool recursive = false)
		{
			create();
			foreach (var file in resolve(srcPath, recursive ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly))
				File.Move(file, Path.Combine(this.path, Path.GetFileName(file)));
			return this;
		}

	}

	public class ConfigFolder : Folder
	{
		public ConfigFolder(String path) { m_path = path; }
		public DestFolder name(string subFolderName)
		{
			return new DestFolder(this.extpends(subFolderName));
		}

		public DestFolder debug { get { return name("debug"); } }

		public DestFolder release { get { return name("release"); } }
	}

	public class ArchFolder : Folder
	{
		public ArchFolder(String path) { m_path = path; }
		public ConfigFolder name(string subFolderName)
		{
			return new ConfigFolder(this.extpends(subFolderName));
		}

		public ConfigFolder win32 { get { return name("win32"); } }

		public ConfigFolder x64 { get { return name("x64"); } }
	}

	public class RTLinkFolder : Folder
	{
		public RTLinkFolder(String path) { m_path = path; }
		public ArchFolder name(string subFolderName)
		{
			return new ArchFolder(this.extpends(subFolderName));
		}

		public ArchFolder dynamicRT { get { return name("rt-dyn"); } }

		public ArchFolder staticRT { get { return name("rt-static"); } }
	}

	public class LibLinkFolder : Folder
	{
		public LibLinkFolder(String path) { m_path = path; }
		public RTLinkFolder name(string subFolderName)
		{
			return new RTLinkFolder(this.extpends(subFolderName));
		}

		public RTLinkFolder dynamicLib { get { return name("dyn"); } }

		public RTLinkFolder staticLib { get { return name("static"); } }
	}

	public class LibSTLFolder : Folder
	{
		public LibSTLFolder(String path) { m_path = path; }
		public LibLinkFolder name(string subFolderName)
		{
			return new LibLinkFolder(this.extpends(subFolderName));
		}

		public LibLinkFolder msvcSTL { get { return name("msvcstl"); } }

		public LibLinkFolder libCXX { get { return name("libcxx"); } }

		public LibLinkFolder libStdCXX { get { return name("libstdcxx"); } }
	}

	public class PlatformFolder : Folder
	{
		public PlatformFolder(String path) { m_path = path; }
		public LibSTLFolder name(string subFolderName)
		{
			return new LibSTLFolder(this.extpends(subFolderName));
		}

		public LibSTLFolder winDesktop { get { return name("windesktop"); } }

		public LibSTLFolder winApp { get { return name("winapp"); } }

		public LibSTLFolder winXP { get { return name("winxp"); } }
		public LibSTLFolder winphone { get { return name("winphone"); } }
	}

	public class ToolsetFolder : Folder
	{
		public ToolsetFolder(String path) { m_path = path; }
		public PlatformFolder name(string subFolderName)
		{
			return new PlatformFolder(this.extpends(subFolderName));
		}

		public PlatformFolder vs120 { get { return name("v120"); } }

		public PlatformFolder vs140 { get { return name("v140"); } }

		public PlatformFolder vs110 { get { return name("v110"); } }
		public PlatformFolder vs100 { get { return name("v100"); } }
	}

	public class RootFolder : Folder
	{
		public RootFolder(String path)
		{
			m_path = path;
			if (!Directory.Exists(path))
				Directory.CreateDirectory(path);
		}
		public DestFolder name(string subFolderName)
		{
			return new DestFolder(this.extpends(subFolderName));
		}

		public DestFolder include { get { return new DestFolder(this.extpends("build/native/include")); } }

		public ToolsetFolder lib { get { return new ToolsetFolder(this.extpends("lib/native")); } }
	}

}
'@ -Language CSharp

function getNuGetPackingRoot {
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType "Container"})]
        [String] $packageRootPath
    )

    New-Object nugetpackagepathfactory.RootFolder $packageRootPath
}
