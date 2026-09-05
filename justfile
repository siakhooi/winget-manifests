set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]
default:
	@just --list

setup:
    winget.exe install wingetcreate

# as System Administrator
enable:
    winget.exe settings --enable LocalManifestFiles

# Windows / GitHub Actions: sync fork, bump manifests, wingetcreate submit
#   just bump
#   just bump jexl-executor picsum
bump *packages:
    powershell.exe -NoProfile -File script/bump.ps1 {{ packages }}
