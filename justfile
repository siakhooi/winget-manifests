setup:
    winget.exe install wingetcreate

# as System Administrator
enable:
    winget.exe settings --enable LocalManifestFiles

#
#  New
#
new:
    wingetcreate.exe new

#
# Next Release
#
update:
    wingetcreate.exe update --urls "{{ packageUrl }}|x64" --version "{{ packageVersion }}"   {{ Author }}.{{ PackageName }}

# Windows / GitHub Actions: sync fork, bump manifests, wingetcreate submit
#   just bump
#   just bump jexl-executor picsum
bump *packages:
    powershell.exe -NoProfile -File script/bump.ps1 {{ packages }}
