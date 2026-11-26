@echo off
setlocal EnableExtensions
title GMXR Module Installer

rem ---- edit these if the repo layout changes -------------------------------
set "GMXR_REPO=Welp111/GMXR"
set "GMXR_BRANCH=main"
set "GMXR_ROOT=Module and all the stuff to compile yourself/output"
set "OXR_INSTALL=1"
set "OXR_TAG=release-1.1.62"
rem -------------------------------------------------------------------------

set "GMXR_HERE=%~dp0"
set "GMXR_SELF=%~f0"
set "GMXR_DIR=%~1"

echo.
echo  =============================================
echo    GMXR  -  Garry's Mod VR binary module setup
echo  =============================================
echo.
echo   Linux / Proton: use install_gmxr_modules.sh instead.
echo.
if not "%GMXR_DIR%"=="" goto RUN
set /p "GMXR_DIR=GarrysMod folder (ENTER = auto-detect): "

:RUN
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((((Get-Content -LiteralPath $env:GMXR_SELF) -match '^#PS') -replace '^#PS ?','') -join [char]10)"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo   Install FAILED with code %RC%.
if "%RC%"=="0" echo   Done. Launch Garry's Mod and type  vrmod_start  in console.
echo.
pause
exit /b %RC%

rem === PowerShell payload below; cmd never reaches it (exit /b above) =======
#PS $ErrorActionPreference='Stop'
#PS $ProgressPreference='SilentlyContinue'
#PS try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}
#PS $repo=$env:GMXR_REPO; $branch=$env:GMXR_BRANCH; $base=$env:GMXR_ROOT
#PS $arch='bin\win64'
#PS $hdr=@{'User-Agent'='GMXR-Installer';'Accept'='application/vnd.github+json'}
#PS if($env:GITHUB_TOKEN){$hdr['Authorization']="Bearer $($env:GITHUB_TOKEN)"}
#PS function Say($m,$c='Gray'){Write-Host $m -ForegroundColor $c}
#PS
#PS # ---------- locate the game ----------
#PS $cand=New-Object Collections.ArrayList
#PS if($env:GMXR_DIR){[void]$cand.Add($env:GMXR_DIR.Trim(' ','"'))}
#PS foreach($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam'){
#PS   $s=$null; try{$s=(Get-ItemProperty -Path $k -ErrorAction Stop).SteamPath}catch{}
#PS   if(-not $s){continue}
#PS   $s=$s -replace '/','\'; $libs=@($s)
#PS   $vdf=Join-Path $s 'steamapps\libraryfolders.vdf'
#PS   if(Test-Path $vdf){foreach($m in [regex]::Matches((Get-Content -Raw $vdf),'"(?:path|\d+)"\s+"([^"]+)"')){$libs+=($m.Groups[1].Value -replace '\\\\','\')}}
#PS   foreach($l in $libs){[void]$cand.Add((Join-Path $l 'steamapps\common\GarrysMod'))}
#PS }
#PS $gm=$null
#PS foreach($c in $cand){
#PS   if([string]::IsNullOrWhiteSpace($c)){continue}
#PS   if(Test-Path (Join-Path $c 'garrysmod\lua')){$gm=(Resolve-Path $c).Path;break}
#PS   if((Split-Path $c -Leaf) -eq 'garrysmod' -and (Test-Path (Join-Path $c 'lua'))){$gm=(Resolve-Path (Split-Path $c -Parent)).Path;break}
#PS }
#PS $staged=$false
#PS if(-not $gm){$staged=$true; $gm=Join-Path $env:GMXR_HERE 'GMXR_win_files'}
#PS $bin=Join-Path $gm 'garrysmod\lua\bin'
#PS $extra=Join-Path $gm $arch
#PS [void](New-Item -ItemType Directory -Force -Path $bin)
#PS $x64=$true
#PS if($staged){[void](New-Item -ItemType Directory -Force -Path $extra)}
#PS elseif(-not (Test-Path $extra)){$x64=$false;$extra=$gm}
#PS if($staged){Say "  GarrysMod not found - staging a copyable folder tree at:" Yellow; Say "  $gm" Yellow}
#PS else{Say "  GarrysMod: $gm" Green}
#PS if(-not $x64){
#PS   Say ''
#PS   Say "  $arch is MISSING - this looks like the 32-bit main branch of Garry's Mod." Red
#PS   Say '  GMXR needs the 64-bit build. In Steam:' Yellow
#PS   Say '    Library > right-click Garry''s Mod > Properties > Betas' Yellow
#PS   Say '    > Beta Participation: x86-64 - Chromium + 64-bit binaries' Yellow
#PS   Say '  Let it update, then run this installer again.' Yellow
#PS   Say '  Continuing anyway - the loader step will be skipped.' DarkGray
#PS }
#PS Say ''
#PS
#PS # ---------- list the module folder ----------
#PS # top level only: subfolders (linux_loader, src) are never installed
#PS try{$found=@((Invoke-RestMethod -Headers $hdr -Uri "https://api.github.com/repos/$repo/contents/$([uri]::EscapeUriString($base))?ref=$branch")|ForEach-Object{$_})}catch{
#PS   Say "  Cannot read $base from $repo" Red
#PS   Say "  $($_.Exception.Message)" Red
#PS   if($_.Exception.Message -match '404'){
#PS     Say "  The repo has no '$base' folder on branch '$branch' (or it is private)." Yellow
#PS     Say "  Push the DLLs to $repo/$base, or edit GMXR_ROOT at the top of this file." Yellow
#PS     exit 4
#PS   }
#PS   Say '  GitHub rate limit or private repo. Set GITHUB_TOKEN and retry:' Yellow
#PS   Say '     set GITHUB_TOKEN=ghp_yourtoken' Yellow
#PS   exit 3
#PS }
#PS $sel=@($found|Where-Object{$_.type -eq 'file' -and $_.name -match '\.dll$' -and $_.name -notmatch 'win32|linux'})
#PS if($sel.Count -eq 0){
#PS   Say "  No Windows x64 DLLs in $base. Saw:" Red
#PS   $found|ForEach-Object{Say "    $($_.path)"}
#PS   exit 4
#PS }
#PS
#PS # ---------- download (skip files already matching the git blob hash) ----------
#PS function GitSha($f){
#PS   $b=[IO.File]::ReadAllBytes($f)
#PS   $p=[Text.Encoding]::ASCII.GetBytes("blob $($b.Length)`0")
#PS   (([Security.Cryptography.SHA1]::Create().ComputeHash([byte[]]($p+$b))|ForEach-Object{$_.ToString('x2')}) -join '')
#PS }
#PS $new=0;$same=0
#PS foreach($f in $sel){
#PS   $dst=$(if($f.name -match '^gm(cl|sv)_'){$bin}else{$extra})
#PS   $out=Join-Path $dst $f.name
#PS   if((Test-Path $out) -and (GitSha $out) -eq $f.sha){Say "   = $($f.name)  up to date" DarkGray;$same++;continue}
#PS   if(Test-Path $out){Copy-Item $out "$out.bak" -Force}
#PS   try{Invoke-WebRequest -UseBasicParsing -Headers $hdr -Uri $f.download_url -OutFile $out}
#PS   catch{
#PS     Say "   x $($f.name): $($_.Exception.Message)" Red
#PS     if($_.Exception.Message -match 'used by another process'){Say '     Close Garry''s Mod and run this again.' Yellow}
#PS     if(Test-Path "$out.bak"){Move-Item "$out.bak" $out -Force}
#PS     exit 5
#PS   }
#PS   Say ("   + {0}  {1:N0} bytes  ->  {2}" -f $f.name,(Get-Item $out).Length,$dst) Green
#PS   $new++
#PS }
#PS
#PS # ---------- OpenXR loader ----------
#PS if($env:OXR_INSTALL -ne '1'){Say '   . OpenXR loader step disabled.' DarkGray}
#PS elseif(-not $x64){Say '   . No bin\win64 to install the loader into - skipped.' Yellow}
#PS elseif($sel|Where-Object{$_.name -eq 'openxr_loader.dll'}){Say '   = openxr_loader.dll shipped by the repo - keeping that copy.' DarkGray}
#PS else{
#PS   $dll=Join-Path $extra 'openxr_loader.dll'
#PS   $tag=$env:OXR_TAG
#PS   try{$tag=(Invoke-RestMethod -Headers $hdr -Uri 'https://api.github.com/repos/KhronosGroup/OpenXR-SDK/releases/latest').tag_name}catch{}
#PS   $ver=$tag -replace '^release-',''
#PS   $have=$null; if(Test-Path $dll){$have=(Get-Item $dll).VersionInfo.FileVersion}
#PS   if($have -and $have.StartsWith($ver)){Say "   = openxr_loader.dll  $have  up to date" DarkGray;$same++}
#PS   else{
#PS     $tmp=Join-Path $env:TEMP "oxr_$ver.nupkg"; $placed=$false
#PS     try{
#PS       Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/KhronosGroup/OpenXR-SDK/releases/download/$tag/OpenXR.Loader.$ver.nupkg" -OutFile $tmp
#PS       Add-Type -AssemblyName System.IO.Compression.FileSystem
#PS       $z=[IO.Compression.ZipFile]::OpenRead($tmp)
#PS       $e=$z.Entries|Where-Object{$_.FullName -eq 'native/x64/release/bin/openxr_loader.dll'}|Select-Object -First 1
#PS       if(-not $e){$z.Dispose();throw 'x64 loader missing from package'}
#PS       if(Test-Path $dll){Copy-Item $dll "$dll.bak" -Force}
#PS       [IO.Compression.ZipFileExtensions]::ExtractToFile($e,$dll,$true); $placed=$true
#PS       $z.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue
#PS       $fs=[IO.File]::OpenRead($dll); $br=New-Object IO.BinaryReader $fs
#PS       $fs.Position=0x3C; $fs.Position=$br.ReadInt32()+4; $m=$br.ReadUInt16(); $br.Close(); $fs.Close()
#PS       if($m -ne 0x8664){throw ('not a 64-bit DLL (machine 0x{0:X})' -f $m)}
#PS       Say ("   + openxr_loader.dll  {0}  {1:N0} bytes  ->  {2}" -f $ver,(Get-Item $dll).Length,$extra) Green
#PS       $new++
#PS     }catch{
#PS       Say "   x openxr_loader.dll: $($_.Exception.Message)" Red
#PS       if($_.Exception.Message -match 'used by another process'){Say '     Close Garry''s Mod and run this again.' Yellow}
#PS       if(Test-Path "$dll.bak"){Move-Item "$dll.bak" $dll -Force}elseif($placed){Remove-Item $dll -Force -ErrorAction SilentlyContinue}
#PS       Remove-Item $tmp -Force -ErrorAction SilentlyContinue
#PS       exit 6
#PS     }
#PS   }
#PS }
#PS
#PS # ---------- active runtime check ----------
#PS $rt=$null
#PS try{$rt=(Get-ItemProperty 'HKLM:\SOFTWARE\Khronos\OpenXR\1' -ErrorAction Stop).ActiveRuntime}catch{}
#PS if($env:XR_RUNTIME_JSON){$rt=$env:XR_RUNTIME_JSON}
#PS if($rt){Say "   . active OpenXR runtime: $rt" DarkGray}
#PS else{Say '   ! No active OpenXR runtime registered - install/launch SteamVR, the Meta app, or VDXR.' Yellow}
#PS Say ''
#PS Say "  $new installed / updated, $same already current." Cyan
#PS if($staged){Say '  Copy the garrysmod\ and bin\ folders from the staged path into your GarrysMod install.' Yellow}
#PS exit 0
