#!/usr/bin/env bash
# GMXR module installer for Linux.
# Targets the WINDOWS build of Garry's Mod running through Proton - the native
# Linux build is not supported, so this installs the win64 modules.
#
#   usage: ./install_gmxr_modules.sh [GarrysMod folder]     (no folder = auto-detect)
#   needs: curl, python3, sha1sum

# ---- edit these (or export them) if the repo layout changes -----------------
REPO="${GMXR_REPO:-Welp111/GMXR}"
BRANCH="${GMXR_BRANCH:-main}"
ROOT="${GMXR_ROOT:-Module and all the stuff to compile yourself/output}"
OXR_INSTALL="${OXR_INSTALL:-1}"
OXR_TAG="${OXR_TAG:-release-1.1.62}"
# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -t 1 ]; then R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' D=$'\e[90m' N=$'\e[0m'; else R= G= Y= C= D= N=; fi
say(){ printf '%s%s%s\n' "${2:-}" "$1" "$N"; }
die(){ say "$2" "$R"; echo; say "  Install FAILED with code $1." "$R"; exit "$1"; }

echo
echo " ============================================="
echo "   GMXR  -  Garry's Mod VR module setup (Proton)"
echo " ============================================="
echo
for t in curl python3 sha1sum; do command -v "$t" >/dev/null || die 2 "  Missing required tool: $t"; done

# ---------- locate the game ----------
cand=()
[ -n "$1" ] && cand+=("${1%/}")
for s in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
         "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
         "$HOME/snap/steam/common/.local/share/Steam"; do
  [ -d "$s/steamapps" ] || continue
  cand+=("$s/steamapps/common/GarrysMod")
  [ -f "$s/steamapps/libraryfolders.vdf" ] && while IFS= read -r l; do
    cand+=("$l/steamapps/common/GarrysMod")
  done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$s/steamapps/libraryfolders.vdf")
done
gm=
for c in "${cand[@]}"; do
  if [ -d "$c/garrysmod/lua" ]; then gm="$(cd "$c" && pwd)"; break; fi
  if [ "${c##*/}" = garrysmod ] && [ -d "$c/lua" ]; then gm="$(cd "$c/.." && pwd)"; break; fi
done
staged=0
[ -z "$gm" ] && { staged=1; gm="$HERE/GMXR_proton_files"; }
bin="$gm/garrysmod/lua/bin"; extra="$gm/bin/win64"; x64=1
mkdir -p "$bin" || die 2 "  Cannot create $bin"
if [ $staged = 1 ]; then
  mkdir -p "$extra"
  say "  GarrysMod not found - staging a copyable folder tree at:" "$Y"; say "  $gm" "$Y"
else
  say "  GarrysMod: $gm" "$G"
  if [ ! -d "$extra" ]; then
    x64=0; extra="$gm"
    echo
    say "  bin/win64 is MISSING - Steam has not installed the 64-bit Windows build." "$R"
    say "  In Steam: Library > right-click Garry's Mod > Properties, then" "$Y"
    say "    Compatibility > Force the use of a specific Steam Play compatibility tool > Proton" "$Y"
    say "    Betas > Beta Participation: x86-64 - Chromium + 64-bit binaries" "$Y"
    say "  Let it update, then run this installer again." "$Y"
    say "  Continuing anyway - the loader step will be skipped." "$D"
  fi
fi
echo

# ---------- list the module folder (one tree call; Windows x64 DLLs only) ----------
auth=(); [ -n "$GITHUB_TOKEN" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
get(){ curl -fsSL -A GMXR-Installer "${auth[@]}" "$@"; }
tree="$(get -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/git/trees/$BRANCH?recursive=1")" || {
  say "  Cannot read $ROOT from $REPO" "$R"
  say "  Private repo or GitHub rate limit. Set GITHUB_TOKEN and retry:" "$Y"
  say "     GITHUB_TOKEN=ghp_yourtoken $0" "$Y"
  die 3 ""
}
sel="$(python3 -c '
import json, re, sys
from urllib.parse import quote
root = sys.argv[1].strip("/") + "/"
for t in json.load(sys.stdin)["tree"]:
    p = t["path"]
    # Windows 64-bit DLLs sitting directly in the root only: no subfolders
    # (linux_loader/, src/), no win32, nothing Linux.
    if t["type"] == "blob" and p.startswith(root) and re.fullmatch(r"(?!.*(win32|linux))[^/]+\.dll", p[len(root):], re.I):
        print(t["sha"] + "\t" + p + "\t" + quote(p))
' "$ROOT" <<<"$tree")"
[ -n "$sel" ] || die 4 "  No Windows x64 DLLs directly under $ROOT/ in $REPO ($BRANCH)."

# ---------- download (skip files already matching the git blob hash) ----------
gitsha(){ { printf 'blob %s\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -c1-40; }
new=0; same=0
while IFS=$'\t' read -r sha path url; do
  name="${path##*/}"
  case "$name" in gmcl_*|gmsv_*) dst="$bin";; *) dst="$extra";; esac
  out="$dst/$name"
  if [ -f "$out" ] && [ "$(gitsha "$out")" = "$sha" ]; then say "   = $name  up to date" "$D"; same=$((same+1)); continue; fi
  if ! get -o "$out.part" "https://raw.githubusercontent.com/$REPO/$BRANCH/$url" \
     || [ "$(gitsha "$out.part")" != "$sha" ] || ! mv -f "$out.part" "$out"; then
    rm -f "$out.part"
    die 5 "   x $name: download failed, hash mismatch, or file not writable (close Garry's Mod and retry)"
  fi
  say "   + $name  $(stat -c %s "$out") bytes  ->  $dst" "$G"; new=$((new+1))
done <<<"$sel"

# ---------- OpenXR loader (Windows DLL - the game runs under Proton) ----------
if [ "$OXR_INSTALL" != 1 ]; then say "   . OpenXR loader step disabled." "$D"
elif [ $x64 = 0 ]; then say "   . No bin/win64 to install the loader into - skipped." "$Y"
elif grep -q '/openxr_loader\.dll	' <<<"$sel"; then say "   = openxr_loader.dll shipped by the repo - keeping that copy." "$D"
else
  dll="$extra/openxr_loader.dll"
  tag="$(get https://api.github.com/repos/KhronosGroup/OpenXR-SDK/releases/latest 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  tag="${tag:-$OXR_TAG}"; ver="${tag#release-}"
  # installed version = the UTF-16 version string inside the DLL's version resource
  if [ -f "$dll" ] && python3 -c 'import sys; sys.exit(sys.argv[2].encode("utf-16-le") not in open(sys.argv[1], "rb").read())' "$dll" "$ver"; then
    say "   = openxr_loader.dll  $ver  up to date" "$D"; same=$((same+1))
  else
    tmp="$(mktemp)"
    if curl -fsSL -o "$tmp" "https://github.com/KhronosGroup/OpenXR-SDK/releases/download/$tag/OpenXR.Loader.$ver.nupkg" && python3 -c '
import struct, sys, zipfile
d = zipfile.ZipFile(sys.argv[1]).read("native/x64/release/bin/openxr_loader.dll")
m = struct.unpack_from("<H", d, struct.unpack_from("<I", d, 0x3C)[0] + 4)[0]
if m != 0x8664: sys.exit("not a 64-bit DLL (machine 0x%X)" % m)
open(sys.argv[2], "wb").write(d)
' "$tmp" "$dll.part" && mv -f "$dll.part" "$dll"; then
      rm -f "$tmp"
      say "   + openxr_loader.dll  $ver  $(stat -c %s "$dll") bytes  ->  $extra" "$G"; new=$((new+1))
    else
      rm -f "$tmp" "$dll.part"
      die 6 "   x openxr_loader.dll: download or extract failed"
    fi
  fi
fi

# ---------- host OpenXR runtime check (Proton bridges to this) ----------
rt="$XR_RUNTIME_JSON"
[ -z "$rt" ] && for f in "${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json" \
                         /etc/xdg/openxr/1/active_runtime.json /usr/share/openxr/1/active_runtime.json; do
  [ -e "$f" ] && { rt="$(readlink -f "$f")"; break; }
done
if [ -n "$rt" ]; then say "   . active OpenXR runtime (host): $rt" "$D"
else say "   ! No active OpenXR runtime found on the host - install/launch SteamVR (or your runtime of choice)." "$Y"; fi

echo
say "  $new installed / updated, $same already current." "$C"
[ $staged = 1 ] && say "  Copy the garrysmod/ and bin/ folders from the staged path into your GarrysMod install." "$Y"
echo
echo "  Done. Launch Garry's Mod through Proton and type  vrmod_start  in console."
echo
